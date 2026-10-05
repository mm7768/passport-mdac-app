param([Parameter(Mandatory)][string]$HeartbeatPath)
# Local dummy only. No network, business tasks or credentials.
while($true){[IO.File]::WriteAllText($HeartbeatPath,[DateTime]::UtcNow.ToString('o'));Start-Sleep -Seconds 1}
