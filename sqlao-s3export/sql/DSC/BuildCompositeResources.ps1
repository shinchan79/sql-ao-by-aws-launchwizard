[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [String]
    $ModuleName,

    [Parameter(Mandatory=$true)]
    [String]
    $InputPath # Must end with '\' or '/'

)

# Create new directory to hold the new module
$ModuleFolder = "C:\Program Files\WindowsPowerShell\Modules"
New-Item -Path $ModuleFolder\$ModuleName -ItemType Directory -Force

# Build the structure of the module
New-ModuleManifest -Path $ModuleFolder\$ModuleName\$ModuleName.psd1
New-Item -Path $ModuleFolder\$ModuleName\DSCResources -ItemType Directory -Force

# Get list of PowerShell files to convert
$PSFilePath = $InputPath + '*'
$ListOfPSFiles = Get-ChildItem -Path $PSFilePath -Include *.ps1

# Convert the PS files to composite resources and put them in the new module
foreach ($FilePath in $ListOfPSFiles) {
    $FileName = [io.path]::GetFileNameWithoutExtension($FilePath)
    New-Item -Path $ModuleFolder\$ModuleName\DSCResources\$FileName -ItemType Directory -Force
    New-Item -Path $ModuleFolder\$ModuleName\DSCResources\$FileName\$FileName.schema.psm1 -ItemType File -Force
    New-ModuleManifest -Path $ModuleFolder\$ModuleName\DSCResources\$FileName\$FileName.psd1 -RootModule .\$FileName.schema.psm1
    Get-Content $FilePath | Out-File $ModuleFolder\$ModuleName\DSCResources\$FileName\$FileName.schema.psm1
}