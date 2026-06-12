# Certificate helpers — PowerShell companion to lib/certs.sh.
# Uses Windows Certificate Store and New-SelfSignedCertificate.
# Admin elevation is required for trust store operations.

function generate_self_signed_cert {
    param(
        [string]$DnsName    = 'localhost',
        [string]$OutputDir  = '.',
        [string]$CertName   = 'selfsigned'
    )
    $cert = New-SelfSignedCertificate `
        -DnsName $DnsName `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(1)

    $pfxPath = Join-Path $OutputDir "$CertName.pfx"
    $cerPath = Join-Path $OutputDir "$CertName.cer"

    Export-PfxCertificate  -Cert $cert -FilePath $pfxPath -Password ([securestring]::new()) | Out-Null
    Export-Certificate     -Cert $cert -FilePath $cerPath | Out-Null

    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Certificate generated: $cerPath / $pfxPath" }
    return @{ CerPath = $cerPath; PfxPath = $pfxPath; Thumbprint = $cert.Thumbprint }
}

function trust_cert {
    param([string]$CertPath)
    if (-not (Get-Command is_admin -ErrorAction SilentlyContinue) -or -not (is_admin)) {
        if (Get-Command log_warn -ErrorAction SilentlyContinue) { log_warn "Admin elevation required to trust certificates." }
        return $false
    }
    Import-Certificate -FilePath $CertPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
    if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Certificate trusted: $CertPath" }
    return $true
}
