#Requires -Version 7.0
<#
.SYNOPSIS
    Copies files from an on-prem SMB share to an Azure File Share, preserving
    folder structure and NTFS ACLs.

.DESCRIPTION
    Uses robocopy to mirror directory structure and file data, then uses
    icacls to back up NTFS ACLs from the source tree and restore them on the
    mapped Azure file share drive.

    Prerequisites:
      - The Azure file share must be mounted as a drive letter (net use or
        New-PSDrive) from a domain-joined machine
      - The storage account must be domain-joined to AD DS for identity-based
        share-level + NTFS permissions to work
      - The user running this script needs:
          * Read access to the source share and its ACLs
          * "Storage File Data SMB Share Elevated Contributor" (or Contributor)
            on the Azure file share for setting ACLs

    Why robocopy + icacls instead of Azure File Sync or AzCopy?
      - robocopy /MIR preserves directory timestamps and can run incremental syncs
      - icacls /save + /restore gives full NTFS ACL fidelity
      - AzCopy doesn't preserve NTFS ACLs
      - Azure File Sync is for ongoing hybrid scenarios; this script is for
        one-time migration

    Ref: https://learn.microsoft.com/azure/storage/files/storage-files-identity-ad-ds-assign-permissions
    Ref: https://learn.microsoft.com/windows-server/administration/windows-commands/robocopy
    Ref: https://learn.microsoft.com/windows-server/administration/windows-commands/icacls

.PARAMETER SourcePath
    UNC path to the on-prem source share. E.g., \\fileserver\departmentshare

.PARAMETER DestinationDriveLetter
    Drive letter where the Azure file share is mounted. E.g., Z:

.PARAMETER LogDirectory
    Directory for robocopy and icacls log files. Defaults to .\logs under the
    script directory.

.PARAMETER WhatIf
    Preview mode -- logs what would be copied but doesn't actually write data.

.EXAMPLE
    # Mount the Azure file share first:
    net use Z: \\storageaccount.file.core.windows.net\department-shared /persistent:yes

    # Then run the copy:
    .\Copy-FilesToAzure.ps1 -SourcePath '\\fileserver01\shared' -DestinationDriveLetter 'Z:'

.EXAMPLE
    # Dry run to see what would happen:
    .\Copy-FilesToAzure.ps1 -SourcePath '\\fileserver01\shared' -DestinationDriveLetter 'Z:' -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Z]:$')]
    [string]$DestinationDriveLetter,

    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Create log directory if it doesn't exist
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$robocopyLog = Join-Path $LogDirectory "robocopy-$timestamp.log"
$aclBackupFile = Join-Path $LogDirectory "acl-backup-$timestamp.txt"
$aclRestoreLog = Join-Path $LogDirectory "acl-restore-$timestamp.log"

function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor $Color
}

# Validate the destination is accessible
$destRoot = "$DestinationDriveLetter\"
if (-not (Test-Path $destRoot)) {
    Write-Error "Destination $destRoot is not accessible. Is the Azure file share mounted?"
}

# ---------------------------------------------------------------------------
# Step 1: Robocopy -- mirror the directory structure and file contents
#
# /MIR   = mirror mode (copies everything, deletes extras at dest)
# /COPY:DATSOU = Data, Attributes, Timestamps, Security (ACLs), Owner, aUditing
# /SECFIX = fix security on already-copied files (incremental ACL updates)
# /R:3   = retry 3 times on failure (default is 1 million, which hangs forever)
# /W:5   = wait 5 seconds between retries
# /MT:16 = 16 threads (Azure Files handles concurrent writes fine)
# /NP    = don't show per-file progress (cleaner logs)
# /LOG   = log to file for post-migration review
#
# Robocopy exit codes: 0-7 are success/info, 8+ are errors.
# Ref: https://learn.microsoft.com/windows-server/administration/windows-commands/robocopy
# ---------------------------------------------------------------------------

Write-Status "Step 1: Copying files from $SourcePath to $destRoot"
Write-Status "        Robocopy log: $robocopyLog"

$robocopyArgs = @(
    $SourcePath
    $destRoot
    '/MIR'
    '/COPY:DATSOU'
    '/SECFIX'
    '/R:3'
    '/W:5'
    '/MT:16'
    '/NP'
    "/LOG:$robocopyLog"
)

if ($WhatIf) {
    # /L = list only mode -- robocopy reports what it would do but writes nothing
    $robocopyArgs += '/L'
    Write-Status 'Running in WhatIf mode -- no files will be written' 'Yellow'
}

& robocopy @robocopyArgs

$robocopyExit = $LASTEXITCODE

if ($robocopyExit -ge 8) {
    Write-Error "Robocopy failed with exit code $robocopyExit. Check the log: $robocopyLog"
} else {
    Write-Status "Robocopy completed with exit code $robocopyExit (0-7 = success)" 'Green'
}

# ---------------------------------------------------------------------------
# Step 2: ACL backup and restore
#
# Even though robocopy /COPY:DATSOU copies ACLs, there are edge cases where
# inherited vs explicit ACLs don't transfer cleanly (especially with deeply
# nested folder structures). This step does a belt-and-suspenders backup/restore
# using icacls, which gives you a human-readable ACL dump for audit purposes too.
#
# /save   = exports ACLs from every file/folder in the source tree to a text file
# /restore = applies those saved ACLs to the destination tree
# /C      = continue on errors (some system files may deny access)
# /T      = apply to all subfolders and files
#
# Ref: https://learn.microsoft.com/windows-server/administration/windows-commands/icacls
# ---------------------------------------------------------------------------

Write-Status "Step 2: Backing up source ACLs to $aclBackupFile"

if (-not $WhatIf) {
    & icacls $SourcePath /save $aclBackupFile /T /C 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "icacls /save had errors (exit code $LASTEXITCODE). Some ACLs may not have been captured. This is common for system-protected files."
    }

    Write-Status "Restoring ACLs to $destRoot"

    & icacls $destRoot /restore $aclBackupFile /C 2>&1 | Tee-Object -FilePath $aclRestoreLog

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "icacls /restore had errors (exit code $LASTEXITCODE). Review $aclRestoreLog for details."
    } else {
        Write-Status 'ACL restore completed successfully.' 'Green'
    }
} else {
    Write-Status 'WhatIf: would back up ACLs from source and restore to destination' 'Yellow'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host '  File Migration Complete' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
Write-Host "  Source:         $SourcePath"
Write-Host "  Destination:    $destRoot"
Write-Host "  Robocopy Log:   $robocopyLog"
Write-Host "  ACL Backup:     $aclBackupFile"
Write-Host "  ACL Restore Log: $aclRestoreLog"
Write-Host ''
Write-Status 'Review the logs above to confirm everything transferred correctly.' 'Green'
Write-Status 'Spot check a few folders to verify ACLs look right: icacls Z:\somefolder' 'White'
Write-Host ''
