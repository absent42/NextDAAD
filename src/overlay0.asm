; Overlay page 0: condact handlers (sub-project 3). Assembled into
; 8K page 56 (bank 28, lower half) at $E000, mapped into slot 7 by
; the dispatcher only.
    MMU 7, OVL0_PAGE, OVL_ORG

ovl0_probe:                     ; Task 1 scaffold proof; replaced by
    ld a, 'V'                   ; real handlers from Task 2 on
    ret

    ASSERT $ <= OVL_LIMIT
