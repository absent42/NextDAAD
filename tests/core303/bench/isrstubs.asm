    ORG IM2_VEC * 257
isr_stub:
    ei
    reti
irq_frame_stub:                  ; vector IM2_V_ULA while irq_setup's carve is in
    jp frame_isr
irq_ctc_stub:                    ; vector IM2_V_CTC0
    jp ctc_isr
    ASSERT high irq_frame_stub == IM2_VEC && high ($ - 1) == IM2_VEC
