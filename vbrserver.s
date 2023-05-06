	INCLUDE "hardware/custom.i"
	INCLUDE "hardware/cia.i"
	INCLUDE "devices/input.i"
	INCLUDE "devices/inputevent.i"
	INCLUDE "resources/potgo.i"
	INCLUDE "lvo/exec_lib.i"
	INCLUDE "lvo/potgo_lib.i"

md_head						equ 0
md_tail						equ 1
md_sigbit					equ 2
md_Task						equ 6
md_potgoResource	equ 10
md_codes					equ 14

* Entered with:       A0 == scratch (execpt for highest pri vertb server)
*  D0 == scratch      A1 == is_Data
*  D1 == scratch      A5 == vector to interrupt code (scratch)
*                     A6 == scratch
*
    SECTION CODE

	; Pin 5 (mouse button 3) is connected to an interrupt enabled pin on the MSP430 controller
	; Toggling this generates an interrupt and mouse controller writes the scroll wheel
	; values to X/Y mouse coordinate delta lines
	XDEF    _VertBServer
_VertBServer:

	; If the middle mouse button being held down do nothing!
	; Just in case we have plain mouse plugged in and MMB is down (line short)
	LEA	_custom,A0
	MOVE.W	potinp(A0), D0					; read POTGOR
	AND.W	#$100, D0									; mask with BIT8
	BEQ.s	abort

	; 256 codes deep FIFO
	; IRQ code is writing to head++
	; driver follows with reading tail++
	; if (head + 1) == tail, we're full
	MOVE.b md_tail(A1),D0						; check where the head and tail is in FIFO
	SUB.b md_head(A1),D0						; if (tail - head) = 1 we're full
	CMP.b #1,D0											; 0010
	BEQ.s	abort

	; Output enable right & middle mouse.  Write 0 to middle
	; 09    OUTLX   Output enable for Paula (pin 32 for DIL and pin 35 for PLCC) -> enable
	; 08    DATLX   I/O data Paula (pin 32 for DIL and pin 35 for PLCC)          -> set low
	MOVE.L	md_potgoResource(A1),A6		; is_Data->potgoResource
	MOVE.L	#$00000200,D0						; word
	MOVE.L	#$00000300,D1						; mask
	JSR	_LVOWritePotgo(A6)					; WritePotgo(word,mask)(d0/d1)

	; Save regs for C code before
	LEA		_custom,A0
	;MOVEA	joy0dat(A0),A5						; store XY just before the pulse (A5)

	; Wait a bit.
	; Mouse controller needs to catch the interrupt and reply on the X/Y mouse coordinate lines

	; cocolino 36,
	; ez-mouse 25
	MOVEQ	#30,D1										; Needs testing on a slower Amiga!
.wait1
	MOVE.B	vhposr+1(A0),D0					; Bits 7-0     H8-H1 (horizontal position)
.wait2
	CMP.B	vhposr+1(A0),D0
	BEQ.s	.wait2
	DBF	D1,	.wait1

	LEA	_custom,A0
	; Save regs for C code after MMB pulse
	MOVE.W	joy0dat(A0),D1				; Mouse Counters (used now)
	AND.W	#$0303,D1							; mask out everything, but the X0,X1, Y0 and Y1

	; move around bits representing quadrature signals from mouse to occupy lower nibble
	ROR.b #$2,D1								; move position 0 and 1 at the position 6 and 7
	LSR.w #$6,D1								; move positino 9 through 7 down to 3:0
	MOVEQ	#0,D0									; just in case clear entire D0
	MOVE.b	md_head(A1),D0			; get the current head counter
	OR.b D1,md_codes(A1,D0.w)		; place current code (bits 0x0003) at the head position
	AND.b	#$0A,D1								; mask out x1 and y1
	LSR.b D1										; shift them over to position of x0 and y0
	EOR.b D1,md_codes(A1,D0.w)	; xor x0 and y0 with x1 and y1

	AND.b #$0F,md_codes(A1,D0.w)	; clear higher nibble just to prepare for LMB and RMB status
; check for the status of LMB line used to represent MMB button
	BTST	#6,$BFE001							; test left mouse button (set Z flag)
	BEQ .lmb_low									; if not pressed do not set flag in message
	BSET #$6,md_codes(A1,D0.w)		; set 5th bit in the message to indicate LMB state
	 															; -> MMB state in cocolino protocol
.lmb_low

; check for the status of RMB line used to indicate non-idle state of scroll wheel
	BTST.W	#10,potinp(A0)			; read POTGOR
	BEQ	.rmb_low								; if not pressed do not set flag in message
	BSET.b #$7,md_codes(A1,D0.w)	; set 5th bit in the message to indicate RMB state
.rmb_low

	;
	; Signal the main task
	; delay introduced in code below is enough to confirm reception to MSP430
	;
	MOVE.L	A1,-(SP)						; preserve A1 in the stack
	MOVE.L 4.W,A6								; ExecBase
	MOVE.L md_sigbit(A1),D0			; is_Data->sigbit
	MOVE.L md_Task(A1),A1				; is_Data->task
	JSR _LVOSignal(A6)
	MOVE.L	(SP)+,A1						; restore A1 from the stack

	LEA		_custom,A0						; restore A0

	MOVEQ   #6,D1								; Needs testing on a slower Amiga!
.wait3
	MOVE.B vhposr+1(A0),D0			; Bits 7-0     H8-H1 (horizontal position)
.wait4
	CMP.B vhposr+1(A0),D0
	BEQ.s   .wait4
	DBF     D1,     .wait3

	ADD.b	#$1,md_head(A1)				; increment message counter

exit:
	; Output enable right & middle mouse.  Write 1 to middle
	; 09    OUTLX   Output enable for Paula (pin 32 for DIL and pin 35 for PLCC) -> enable
	; 08    DATLX   I/O data Paula (pin 32 for DIL and pin 35 for PLCC)          -> set high
	MOVE.L	md_potgoResource(A1),A6						; is_Data
	MOVE.L	#$00000300,D0				; word
	MOVE.L	D0,D1								; mask
	JSR	_LVOWritePotgo(A6)			; WritePotgo(word,mask)(d0/d1)

abort:
	LEA		_custom,A0					; if you install a vertical blank server at priority 10 or greater, you must place custom ($DFF000) in A0 before exiting
	MOVEQ.L #0,D0					; set Z flag to continue to process other vb-servers
	RTS
