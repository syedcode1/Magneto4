. "$PSScriptRoot\..\_bootstrap.ps1"

Describe 'Protect/Unprotect-Password' -Tag 'Unit','DPAPI' {

    It 'round-trips an ASCII password' {
        $plain = 'Tr0ub4dor&3'
        $cipher = Protect-Password -PlainPassword $plain
        $cipher | Should -Not -BeNullOrEmpty
        $cipher | Should -Not -Be $plain
        (Unprotect-Password -EncryptedPassword $cipher) | Should -Be $plain
    }

    It 'round-trips a Unicode password (UTF-8 boundary coverage)' {
        # Source file kept ASCII-safe; Unicode built at runtime so PS 5.1 parser
        # never has to interpret non-ASCII bytes from disk. Covers all UTF-8
        # length classes: 1-byte ASCII, 2-byte Latin-1 (U+00F6 o-umlaut),
        # 3-byte CJK (U+6D4B, U+8BD5), 4-byte via surrogate pair (U+1F512 lock).
        $oUml  = [char]0x00F6
        $cjk1  = [char]0x6D4B
        $cjk2  = [char]0x8BD5
        $lockH = [char]0xD83D
        $lockL = [char]0xDD12
        $plain = "P@ssw${oUml}rd_${cjk1}${cjk2}_${lockH}${lockL}"

        $cipher = Protect-Password -PlainPassword $plain
        $cipher | Should -Not -BeNullOrEmpty
        $cipher | Should -Not -Be $plain
        (Unprotect-Password -EncryptedPassword $cipher) | Should -Be $plain
    }

    It 'returns empty string for empty input on both sides' {
        (Protect-Password -PlainPassword '') | Should -Be ''
        (Unprotect-Password -EncryptedPassword '') | Should -Be ''
    }

    It 'throws on invalid base64 input' {
        # Intent: surface the error instead of silently corrupting callers.
        { Unprotect-Password -EncryptedPassword 'not!valid@base64!!' } | Should -Throw -ExpectedMessage '*Failed to decrypt password (DPAPI)*'
    }

    It 'throws on a valid-base64 but non-DPAPI 128-byte blob, never silently returning ciphertext (Wave 1 regression)' {
        # Fabricate a 128-byte deterministic blob that is valid base64 but is NOT
        # a DPAPI CurrentUser envelope. CryptUnprotectData rejects the header.
        # Wave 1 regression: earlier behavior returned the base64 string as
        # plaintext on failure, silently breaking Invoke-CommandAsUser. This
        # test pins the corrected throw-instead-of-silent-fail contract.
        $bytes = New-Object byte[] 128
        for ($i = 0; $i -lt 128; $i++) { $bytes[$i] = $i }
        $fakeCipher = [Convert]::ToBase64String($bytes)

        $thrown = $false
        $returnValue = $null
        try {
            $returnValue = Unprotect-Password -EncryptedPassword $fakeCipher
        } catch {
            $thrown = $true
            $_.Exception.Message | Should -Match 'Failed to decrypt password \(DPAPI\)'
        }

        $thrown | Should -BeTrue -Because 'Unprotect-Password must throw on a non-DPAPI blob, not silently return ciphertext'
        $returnValue | Should -BeNullOrEmpty -Because 'the regression we are pinning: value must not leak the base64 input back to the caller'
    }

    It 'documents the DPAPI CurrentUser cross-user portability limitation' {
        Set-ItResult -Skipped -Because 'DPAPI CurrentUser scope is non-portable: blobs encrypted by user A cannot be decrypted by user B or on a different machine. Validated manually in multi-host integration; automated cross-user coverage is out of scope.'
    }
}
