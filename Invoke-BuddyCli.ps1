#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$envelope = $env:MY_BUDDY_CLI_ENVELOPE | ConvertFrom-Json
Remove-Item Env:MY_BUDDY_CLI_ENVELOPE
$prompt = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Missing approved task prompt.' }
$arguments = @($envelope.arguments)
# Use stdin without -p: Copilot otherwise silently ignores piped task context.
$prompt | & $envelope.executable @arguments
exit $LASTEXITCODE
