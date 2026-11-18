[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [guid]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = 'rg-os-upgrade-2025',

    [ValidateNotNullOrEmpty()]
    [string]$Location = 'eastus',

    [ValidateSet('', '1', '2', '3')]
    [string]$Zone = '',

    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,65}$')]
    [string]$DiskNamePrefix = 'Disk-WindowsServer2025Upgrade',

    [ValidateSet('server2025Upgrade', 'server2022Upgrade', 'server2019Upgrade', 'server2016Upgrade', 'server2012Upgrade')]
    [string]$TargetSku = 'server2025Upgrade'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($SubscriptionId -eq [guid]::Empty) {
    throw 'SubscriptionId must be the subscription GUID for sub-it-prod, not an empty GUID.'
}

$publisher = 'MicrosoftWindowsServer'
$offer = 'WindowsServerUpgrade'
$managedDiskSku = 'Standard_LRS'
$runbookOwner = 'New-WindowsServer2025UpgradeDisk'
$createdUtc = [datetime]::UtcNow
$easternZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$month = [TimeZoneInfo]::ConvertTimeFromUtc($createdUtc, $easternZone).ToString('yyyyMM')
$diskName = $DiskNamePrefix

try {
    $null = Disable-AzContextAutosave -Scope Process
    $connection = (Connect-AzAccount -Identity -Subscription $SubscriptionId.ToString()).Context
    $azureContext = Set-AzContext -SubscriptionId $SubscriptionId.ToString() -DefaultProfile $connection
    if ($azureContext.Subscription.Id -ne $SubscriptionId.ToString()) {
        throw 'Authenticated Azure context does not match the requested subscription.'
    }

    Write-Output ('SubscriptionId={0}; DiskName={1}; Month={2}' -f $SubscriptionId, $diskName, $month)
    $null = Get-AzResourceGroup -Name $ResourceGroupName -DefaultProfile $azureContext

    $existingDisks = @(Get-AzDisk -ResourceGroupName $ResourceGroupName -DefaultProfile $azureContext)
    $existingDisk = $existingDisks | Where-Object { $_.Name -eq $diskName } | Select-Object -First 1
    if ($null -ne $existingDisk -and $existingDisk.DiskState -ne 'Unattached') {
        throw "Disk '$diskName' has disk state '$($existingDisk.DiskState)' and cannot be replaced unless it is Unattached. No changes were made."
    }

    $versions = @(Get-AzVMImage -PublisherName $publisher -Location $Location -Offer $offer -Skus $TargetSku -DefaultProfile $azureContext |
        Sort-Object -Property { [version]$_.Version } -Descending)
    if ($versions.Count -eq 0) {
        throw "No image versions found for $publisher/$offer/$TargetSku in $Location."
    }

    $latestVersion = $versions[0].Version
    $image = Get-AzVMImage -Location $Location -PublisherName $publisher -Offer $offer -Skus $TargetSku -Version $latestVersion -DefaultProfile $azureContext
    if ([string]::IsNullOrWhiteSpace($image.Id) -or @($image.DataDiskImages | Where-Object { $_.Lun -eq 0 }).Count -eq 0) {
        throw 'The selected upgrade image does not contain the expected data disk at LUN 0.'
    }

    $diskTags = @{
        ManagedBy = $runbookOwner
        DiskNamePrefix = $DiskNamePrefix
        TargetSku = $TargetSku
        MediaMonth = $month
        MediaVersion = $latestVersion
        CreatedUtc = $createdUtc.ToString('o')
    }
    $configParameters = @{
        SkuName = $managedDiskSku
        CreateOption = 'FromImage'
        Location = $Location
        Tag = $diskTags
    }
    if ($Zone) {
        $configParameters['Zone'] = $Zone
    }

    $diskConfig = New-AzDiskConfig @configParameters
    $diskConfig = Set-AzDiskImageReference -Disk $diskConfig -Id $image.Id -Lun 0
    if ($null -ne $existingDisk) {
        Write-Output "Deleting existing unattached disk '$diskName' before replacement."
        $null = Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Force -DefaultProfile $azureContext
    }
    $null = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Disk $diskConfig -DefaultProfile $azureContext
    $createdDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -DefaultProfile $azureContext
    if ($createdDisk.ProvisioningState -ne 'Succeeded') {
        throw "Disk '$diskName' has provisioning state '$($createdDisk.ProvisioningState)'; inspect it before retrying."
    }

    Write-Output ([ordered]@{
        Outcome = 'Created'
        DiskId = $createdDisk.Id
        DiskName = $diskName
        ImageVersion = $latestVersion
        SourceImageId = $image.Id
        Location = $createdDisk.Location
        ProvisioningState = $createdDisk.ProvisioningState
    } | ConvertTo-Json -Compress)
}
catch {
    Write-Error -Message ("Upgrade media disk creation failed: {0}" -f $_.Exception.Message) -ErrorAction Continue
    throw
}