# Monthly Windows Server Upgrade Media

## Deliverables

- `New-WindowsServer2025UpgradeDisk.ps1`: upload this file as the PowerShell runbook.
- `Test-UpgradeMediaRunbook.ps1`: dependency-free offline tests using mocked Azure commands. Do not upload this file as the production runbook.

The runbook creates upgrade media only. It does not attach disks, upgrade VMs, or create resource groups. Each run deletes the existing unattached disk with the configured name and creates a new disk with that same name. The existing disk is deleted regardless of its tags or source, so confirm the configured name before running. Previously created date-suffixed disks are not deleted and continue to incur storage costs. Run only one instance at a time; the existing-disk check is not a distributed lock.

## 1. Identity and Permissions

1. In the Azure portal, open Automation account **aa-it-shared-prod-01**, resource group **rg-automation-it-shared-prod-01**. Record its subscription and current settings.
2. Under **Identity > System assigned**, enable the identity if needed. Do not remove any existing identity assignments.
3. Open subscription **sub-it-prod** and copy its **Subscription ID** GUID for the mandatory runbook parameter. Do not enter the subscription display name in that parameter.
4. On **rg-os-upgrade-2025 > Access control (IAM)**, assign **Contributor** to the Automation account's managed identity, unless equivalent access already exists.
5. On **sub-it-prod > Access control (IAM)**, assign **Reader** to that identity for subscription-level Marketplace image discovery, unless equivalent access already exists. Allow time for role propagation.

This built-in-role baseline is broader than a custom disk-only role: Contributor manages resources in the destination group, and Reader can inspect subscription resource metadata. It grants no subscription-wide writes. Use organization-approved custom roles instead if required. The setup operator needs role-assignment permission as well as Automation configuration access. The runbook itself never assigns roles.

Confirm Microsoft.Compute is registered and that organizational policies permit Standard_LRS managed disks in eastus, including any required tags or disk security settings. Add organization-mandated tags to `$diskTags` before publishing. No live policy or permission checks have been performed by the local tests.

## 2. Dedicated Runtime

1. In the Automation account, open **Process Automation > Runtime environments**. Create a dedicated runtime named **ps74-windows-upgrade-media**, language **PowerShell**, version **7.4**, or reuse a verified compatible runtime.
2. Include compatible versions of **Az.Accounts**, **Az.Compute**, and **Az.Resources**, including their dependencies. Record the selected package versions for future changes. Use the same runtime for testing and production.
3. Do not update shared runtime environments or legacy account-wide modules used by other production runbooks just for this runbook.

No Azure CLI, Hybrid Runbook Worker, VM, stored password, or Az.Automation package is needed inside the runbook. Local offline tests do not establish compatibility of installed cloud runtime packages.

## 3. Create and Test the Runbook

1. Under **Runbooks**, create **New-WindowsServer2025UpgradeDisk**, type **PowerShell**, associated with the dedicated runtime. Import the corresponding script or paste its contents into the editor.
2. Save the draft. Open **Test pane** and select Azure/cloud execution, not a Hybrid Worker.
3. Supply `SubscriptionId` with the actual GUID for sub-it-prod. For the first test use `DiskNamePrefix = Test-WindowsServer2025Upgrade`; this is the exact disk name despite the parameter name. Confirm that no disk with this name needs to be retained. Keep the other defaults: resource group rg-os-upgrade-2025, location eastus, empty Zone, TargetSku server2025Upgrade.
4. Start the test. This creates a real, billable test disk. Expect JSON output with `Outcome = Created`, source image version/ID and disk ID, followed by a Completed job with no errors. In the destination group verify provisioning Succeeded, Standard_LRS, eastus, no availability zone and the ownership/version/month tags.
5. Run the same test again. Expect the existing test disk to be deleted and a new disk created with the same name and resource ID. Each run selects the latest available image, even within the same month.
6. To test failure, use an unavailable image configuration, such as a supported SKU that is not available in the chosen region. Expect a Failed job and the existing disk to remain untouched. Invalid SKU strings are rejected by parameter validation before script execution.
7. Leave test disks in place unless deletion is separately approved. After testing, publish the runbook. Scheduled jobs execute the published version, not an unpublished draft.

The default disk name is **Disk-WindowsServer2025Upgrade**, without a date suffix. Every run selects the latest numerically sorted available image and validates its LUN 0 before deleting the existing disk. Only a disk in the Unattached state can be replaced. If deletion succeeds but creation or provisioning fails, the old disk is already gone and the replacement may be missing or failed; investigate the job before retrying. Read/authorization failures are not treated as missing disks. Do not start overlapping manual and scheduled jobs.

`Set-AzDiskImageReference -Lun 0` selects the upgrade-media data disk inside Microsoft's image; it does not attach the resulting disk to a VM. These regional disks suit nonzonal VMs in eastus. Use matching region/zone settings when preparing media for a zonal VM; one scheduled disk is created, not a disk for every zone or VM.

## 4. Monthly Schedule

From the published runbook, open **Schedules > Add a schedule > Create a new schedule** and configure:

| Setting | Value |
| --- | --- |
| Name | WindowsServer2025UpgradeMonthly |
| Start date | December 15, 2026 |
| Start time | 03:00 AM |
| Time zone | Eastern Time (US & Canada), DST-aware |
| Recurrence | Recurring, every 1 month |
| Monthly occurrences | Week days |
| Occurrence | Third |
| Day | Tuesday |
| Expiration | None, unless organizational policy requires one |
| Execution | Azure |

Select Eastern Standard Time if the UI uses Windows time-zone IDs; that named zone includes EST/EDT rules. Do not select fixed UTC-05:00 or schedule a fixed 08:00 UTC time. Do not substitute day 17 of each month or a four-week interval.

Link this schedule to the published runbook. Set **SubscriptionId** explicitly. Use production defaults, especially **DiskNamePrefix = Disk-WindowsServer2025Upgrade**, not the test prefix. Ensure there is exactly one intended schedule association.

Verify upcoming runs:

| Eastern local time | UTC |
| --- | --- |
| December 15, 2026, 03:00 EST | 08:00 |
| January 19, 2027, 03:00 EST | 08:00 |
| February 16, 2027, 03:00 EST | 08:00 |
| March 16, 2027, 03:00 EDT | 07:00 |

## 5. Operations and Validation

Review this runbook's **Jobs**, **Output** and **Errors** after testing and the first scheduled run. Inspect any Failed or Suspended job; a successful replacement may still use the same image version as the previous run. Resolve failures before manually retrying. Check whether the old disk was deleted and whether a replacement exists before retrying. Enable new email/Log Analytics alerting only through a separately approved configuration.

To pause, disable only **WindowsServer2025UpgradeMonthly**. This does not stop an already running job or remove any existing disks. Do not disable the shared Automation account identity or change unrelated runbooks/runtimes as rollback.

Run offline checks from this folder in PowerShell:

```powershell
.\Test-UpgradeMediaRunbook.ps1
```

Offline checks cover numeric image selection, creation and replacement, regional/zonal configurations, attached disk and deletion rejection, read/auth/context failures, missing images/LUN 0, failed provisioning and Eastern-time boundaries. They use mocked commands and do not authenticate or call Azure. A cloud test is still required for runtime compatibility, actual image availability, subscription permissions and policy compliance.

## References

- https://learn.microsoft.com/en-us/azure/virtual-machines/windows-in-place-upgrade
- https://learn.microsoft.com/en-us/powershell/module/az.compute/set-azdiskimagereference
- https://learn.microsoft.com/en-us/azure/automation/learn/powershell-runbook-managed-identity
- https://learn.microsoft.com/en-us/azure/automation/shared-resources/schedules