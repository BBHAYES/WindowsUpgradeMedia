[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runbookPath = Join-Path $PSScriptRoot 'New-WindowsServer2025UpgradeDisk.ps1'
$subscription = '11111111-1111-1111-1111-111111111111'
$script:state = @{}

function Disable-AzContextAutosave { param($Scope) }
function Connect-AzAccount {
    param([switch]$Identity, $Subscription)
    if (-not $Identity) { throw 'Managed identity must be used.' }
    [pscustomobject]@{ Context = [pscustomobject]@{ Subscription = @{ Id = $Subscription } } }
}
function Set-AzContext {
    param($SubscriptionId, $DefaultProfile)
    if ($script:state.WrongContext) { $SubscriptionId = '22222222-2222-2222-2222-222222222222' }
    [pscustomobject]@{ Subscription = @{ Id = $SubscriptionId } }
}
function Get-AzResourceGroup {
    param($Name, $DefaultProfile)
    if ($script:state.MissingGroup) { throw 'Resource group not found.' }
    [pscustomobject]@{ Name = $Name }
}
function Get-AzDisk {
    param($ResourceGroupName, $DiskName, $DefaultProfile)
    if ($script:state.ReadDenied) { throw 'AuthorizationFailed' }
    if ($null -ne $script:state.Disk) { $script:state.Disk }
}
function Get-AzVMImage {
    param($PublisherName, $Location, $Offer, $Skus, $Version, $DefaultProfile)
    $script:state.ImageReads++
    if ($script:state.NoImages) { return }
    if (-not $Version) {
        [pscustomobject]@{ Version = '20348.9.0' }
        [pscustomobject]@{ Version = '20348.10.0' }
        return
    }
    $dataDisks = @([pscustomobject]@{ Lun = 0 })
    if ($script:state.NoLun) { $dataDisks = @() }
    [pscustomobject]@{
        Id = '/Subscriptions/{0}/Providers/Microsoft.Compute/Locations/{1}/Publishers/{2}/ArtifactTypes/VMImage/Offers/{3}/Skus/{4}/Versions/{5}' -f $subscription, $Location, $PublisherName, $Offer, $Skus, $Version
        DataDiskImages = $dataDisks
    }
}
function New-AzDiskConfig {
    param($SkuName, $CreateOption, $Location, $Tag, $Zone)
    [pscustomobject]@{
        Sku = [pscustomobject]@{ Name = $SkuName }
        Location = $Location
        Zones = @($Zone | Where-Object { $_ })
        Tags = $Tag
        CreationData = [pscustomobject]@{ CreateOption = $CreateOption; ImageReference = $null }
    }
}
function Set-AzDiskImageReference {
    param($Disk, $Id, $Lun)
    $Disk.CreationData.ImageReference = [pscustomobject]@{ Id = $Id; Lun = $Lun }
    $Disk
}
function Remove-AzDisk {
    param($ResourceGroupName, $DiskName, [switch]$Force, $DefaultProfile)
    if ($script:state.DeleteDenied) { throw 'Deletion denied.' }
    if (-not $Force -or $script:state.Disk.Name -ne $DiskName) { throw 'Unexpected disk deletion.' }
    $script:state.Deletes++
    $script:state.Disk = $null
}
function New-AzDisk {
    param($ResourceGroupName, $DiskName, $Disk, $DefaultProfile)
    $script:state.Creates++
    $Disk | Add-Member -NotePropertyName Name -NotePropertyValue $DiskName
    $Disk | Add-Member -NotePropertyName Id -NotePropertyValue "/subscriptions/$subscription/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/disks/$DiskName"
    $provisioningState = 'Succeeded'
    if ($script:state.CreateFailed) { $provisioningState = 'Failed' }
    $Disk | Add-Member -NotePropertyName ProvisioningState -NotePropertyValue $provisioningState
    $Disk | Add-Member -NotePropertyName DiskState -NotePropertyValue 'Unattached'
    $script:state.Disk = $Disk
    $Disk
}
function Reset-TestState {
    $script:state = @{
        Disk = $null; Creates = 0; Deletes = 0; ImageReads = 0
        WrongContext = $false; MissingGroup = $false; ReadDenied = $false
        NoImages = $false; NoLun = $false; CreateFailed = $false; DeleteDenied = $false
    }
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Invoke-TestRunbook {
    param([string]$Zone = '')
    $output = @(. $runbookPath -SubscriptionId $subscription -Zone $Zone 2>$null)
    $output[-1] | ConvertFrom-Json
}
function Assert-RunbookFails {
    param([string]$ExpectedMessage)
    $caught = $false
    try { $null = Invoke-TestRunbook }
    catch {
        $caught = $true
        Assert-True ($_.Exception.Message -like "*$ExpectedMessage*") "Expected '$ExpectedMessage', got '$($_.Exception.Message)'."
    }
    Assert-True $caught "Expected failure containing '$ExpectedMessage'."
}

Reset-TestState
$result = Invoke-TestRunbook
Assert-True ($result.Outcome -eq 'Created') 'First run should create a disk.'
Assert-True ($result.ImageVersion -eq '20348.10.0') 'Image versions must sort numerically.'
Assert-True ($script:state.Creates -eq 1) 'Exactly one disk should be created.'
Assert-True ($script:state.Disk.Zones.Count -eq 0) 'Regional disks must omit the zone.'
Assert-True ($result.DiskName -eq 'Disk-WindowsServer2025Upgrade') 'Disk should use the original name.'
$firstDiskId = $result.DiskId
$imageReads = $script:state.ImageReads
$result = Invoke-TestRunbook
Assert-True ($result.Outcome -eq 'Created' -and $result.DiskId -eq $firstDiskId) 'Repeat run should recreate the disk with the same name.'
Assert-True ($script:state.Creates -eq 2 -and $script:state.Deletes -eq 1 -and $script:state.ImageReads -gt $imageReads) 'Repeat run must select the image and replace the disk.'
'PASS: creation, numeric version sorting, regional disk, fixed naming and replacement.'

$script:state.Disk.DiskState = 'Attached'
Assert-RunbookFails 'cannot be replaced unless it is Unattached'
Assert-True ($script:state.Creates -eq 2 -and $script:state.Deletes -eq 1) 'Attached disks must not be deleted.'
$script:state.Disk.DiskState = 'Unattached'
$script:state.DeleteDenied = $true
Assert-RunbookFails 'Deletion denied'
Assert-True ($script:state.Creates -eq 2 -and $script:state.Deletes -eq 1) 'Failed deletion must not create a replacement.'
'PASS: attached disks and deletion failures stop replacement.'

foreach ($scenario in @(
    @{ Flag = 'NoImages'; Message = 'No image versions' },
    @{ Flag = 'NoLun'; Message = 'LUN 0' },
    @{ Flag = 'MissingGroup'; Message = 'Resource group not found' },
    @{ Flag = 'ReadDenied'; Message = 'AuthorizationFailed' },
    @{ Flag = 'WrongContext'; Message = 'does not match' }
)) {
    Reset-TestState
    $null = Invoke-TestRunbook
    $script:state[$scenario.Flag] = $true
    Assert-RunbookFails $scenario.Message
    Assert-True ($script:state.Creates -eq 1 -and $script:state.Deletes -eq 0 -and $null -ne $script:state.Disk) 'Preflight errors must preserve the existing disk.'
    'PASS: {0} fails before replacement.' -f $scenario.Flag
}

Reset-TestState
$script:state.CreateFailed = $true
Assert-RunbookFails "provisioning state 'Failed'"
'PASS: failed provisioning does not report success.'

Reset-TestState
$result = Invoke-TestRunbook -Zone '1'
Assert-True (($script:state.Disk.Zones -join ',') -eq '1') 'Explicit zone should be preserved.'
$result = Invoke-TestRunbook -Zone '1'
Assert-True ($result.Outcome -eq 'Created' -and $script:state.Deletes -eq 1 -and ($script:state.Disk.Zones -join ',') -eq '1') 'Zonal disk replacement should retain its zone.'
'PASS: explicit zone and zonal replacement.'

$easternZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$monthAtBoundary = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::new(2027, 1, 1, 2, 0, 0, [DateTimeKind]::Utc), $easternZone).ToString('yyyyMM')
Assert-True ($monthAtBoundary -eq '202612') 'Media month must follow Eastern time at UTC year boundary.'
foreach ($scheduleCheck in @(
    @{ Local = '2026-12-15T03:00:00'; UtcHour = 8 },
    @{ Local = '2027-01-19T03:00:00'; UtcHour = 8 },
    @{ Local = '2027-02-16T03:00:00'; UtcHour = 8 },
    @{ Local = '2027-03-16T03:00:00'; UtcHour = 7 }
)) {
    $localTime = [datetime]::SpecifyKind([datetime]::Parse($scheduleCheck.Local), [DateTimeKind]::Unspecified)
    $utcTime = [TimeZoneInfo]::ConvertTimeToUtc($localTime, $easternZone)
    Assert-True ($localTime.DayOfWeek -eq 'Tuesday' -and $localTime.Day -ge 15 -and $localTime.Day -le 21) 'Expected third Tuesday.'
    Assert-True ($utcTime.Hour -eq $scheduleCheck.UtcHour) 'Expected correct Eastern daylight-saving offset.'
}
'PASS: Eastern month boundary and third-Tuesday EST/EDT schedule expectations.'
'All offline tests passed. No Azure service calls were made.'