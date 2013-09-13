param($lab)
$lab | % { $_ | Out-Default }
# check if the lab already started
$instances = Get-EC2Tag | ? ResourceType -eq Instance | ? Key -eq Name | ? Value -eq $lab[0].name | % ResourceId | % { Get-EC2InstanceStatus $_ } | ? { $_.InstanceState.Code -eq 16}
if($instances -ne $null) {
  "Lab already started. Exiting..." | Out-Default
  exit -1
}

$config = iex (new-object System.Text.ASCIIEncoding).GetString((Invoke-WebRequest -Uri http://169.254.169.254/latest/user-data -UseBasicParsing).Content)
Set-DefaultAWSRegion us-east-1

# obtain all Private images
$images = Get-EC2Image | ? OwnerId -eq 637921189560

# S3Reader role
$role = Get-IAMInstanceProfileForRole S3Reader

# create spot requests
$lab | % { $_.request = Request-EC2SpotInstance -SpotPrice $_.maxbid -LaunchSpecification_InstanceType $_.type -LaunchSpecification_ImageId ($images | ? Name -eq $_.amiName).ImageId -LaunchSpecification_SecurityGroupId 'Fitnesse' -LaunchSpecification_InstanceProfile_Arn $role.Arn -LaunchSpecification_InstanceProfile_Id $role.InstanceProfileId }

"waiting for spot requests fulfilment..." | Out-Default
do {
  Sleep 60
  # update spot requests information
  $lab | % { $_.request = Get-EC2SpotInstanceRequest $_.request.SpotInstanceRequestId }
  $lab | % { "[$($_.name)]`t$($_.request.Status.Message)" | Out-Default }
} while( ($lab | ? { $_.request.State -eq 'open'} ) -ne $null )

# set instances name
$lab | % { New-EC2Tag -ResourceId $_.request.InstanceId -Tag (new-object Amazon.EC2.Model.Tag).WithKey('Name').WithValue($_.name) }

"wait for instances running..." | Out-Default 
do {
  Sleep 30
} while( ($lab | ? { (Get-EC2InstanceStatus $_.request.InstanceId).InstanceState.Name -ne 'running' }) -ne $null )

"wait for reachability test..." | Out-Default
do {
  Sleep 30
} while( ($lab | ? { (Get-EC2InstanceStatus $_.request.InstanceId).InstanceStatusDetail.Detail.Status -ne 'passed' }) -ne $null )

# get instances
$lab | % { $_.instance = (Get-EC2Instance $_.request.InstanceId).RunningInstance }
$lab | % { "[$($_.name)]`t$($_.instance.PublicDnsName)" | Out-Default }

# update R53
foreach($computer in $lab){
  "[$($computer.name)]`t[R53] update... " | Out-Default
  $result = Get-R53ResourceRecordSet -HostedZoneId $config.HostedZoneId -StartRecordName $computer.name -MaxItems 1
  $rs = $result.ResourceRecordSets[0]
  
  if($rs.Name -eq "$($computer.name).") {
    "[$($computer.name)]`t[R53] entry found" | Out-Default
    "[$($computer.name)]`t[R53] delete entry" | Out-Default
    $action = (new-object Amazon.Route53.Model.Change).WithAction('DELETE').WithResourceRecordSet($rs)
    Edit-R53ResourceRecordSet -HostedZoneId $config.HostedZoneId -ChangeBatch_Changes $action | Out-Null
  } else { "[$($computer.name)]`t[R53] entry not found (returned entry is for $($rs.Name))" | Out-Default }
  "[$($computer.name)]`t[R53] create entry" | Out-Default
  $record = (new-object Amazon.Route53.Model.ResourceRecord).WithValue($computer.instance.PublicDnsName)
  $rs = (new-object Amazon.Route53.Model.ResourceRecordSet).WithName($computer.name).WithType('CNAME').WithTTL('10').WithResourceRecords($record)
  $action = (new-object Amazon.Route53.Model.Change).WithAction('CREATE').WithResourceRecordSet($rs)
  Edit-R53ResourceRecordSet -HostedZoneId $config.HostedZoneId -ChangeBatch_Changes $action | Out-Null
}

"update DNS on clients..." | Out-Default
function Update-DNS($clientIP, $dnsIP) {
  $NICs = Get-WMIObject Win32_NetworkAdapterConfiguration -ComputerName $clientIP | ? IPEnabled -eq 'TRUE'
  foreach($n in $NICs) {$n.SetDNSServerSearchOrder($dnsIP); $n.SetDynamicDNSRegistration('TRUE')}
}
# first computer is DNS
$lab | select -skip 1 | % { Update-DNS $_.instance.PrivateIpAddress $lab[0].instance.PrivateIpAddress | Out-Null }

"disable IEESC..." | Out-Default
Invoke-Command -computer $lab.instance.PrivateIpAddress -script {
  '{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}','{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' | % { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$_" -Name 'IsInstalled' -Value 0 }
}

"disable firewall..." | Out-Default
Invoke-Command -computer $lab.instance.PrivateIpAddress -script {
  netsh advfirewall set allprofiles state off
}

function Test-TcpPort($target, $port)
{
    $ErrorActionPreference = 'SilentlyContinue'
    $s = new-object Net.Sockets.TcpClient
    $s.Connect($target, $port)
    if ($s.Connected) {
        $s.Close()
        return $true
    }
    return $false
}
if($config.fitnesse -ne $null) {
  "wait for PowerSlim response..." | Out-Default
  do {
    Sleep 60
    $lab | ? { $_.PowerSlim -ne $true } | % { $_.PowerSlim = Test-TcpPort $_.name 35 }
    $lab | % { "[$($_.name)]`tPowerSlim = $($_.PowerSlim)" | Out-Default }
  } while( ($lab | ? { $_.PowerSlim -ne $true }) -ne $null )
}

