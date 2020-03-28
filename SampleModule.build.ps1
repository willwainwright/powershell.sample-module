#requires -modules InvokeBuild

<#
.SYNOPSIS
    Build script (https://github.com/nightroman/Invoke-Build)

.DESCRIPTION
    This script contains the tasks for building the 'SampleModule' PowerShell module
#>

Set-StrictMode -Version Latest

# Synopsis: Default task
task . Build

# Synopsis: Build the project
task Build UpdateModuleManifest, UpdatePackageSpecification, CopyFiles

# Synopsis: Perform clean build of the project
task CleanBuild Clean, Build

# Setting build script variables
$moduleName = 'SampleModule'
$moduleSourcePath = Join-Path -Path $PSScriptRoot -ChildPath $moduleName
$buildOutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'build'

# Setting base module version
$newModuleVersion = New-Object -TypeName 'System.Version' -ArgumentList (0, 0, 1)

# Install build dependencies
Enter-Build {
    if (-not (Get-Module -Name PSDepend -ListAvailable)) {
        Install-Module PSDepend -Force
    }
    Import-Module PSDepend
    Invoke-PSDepend -Force
}

# Synopsis: Analyze the project with PSScriptAnalyzer
task Analyze {
    # Get-ChildItem parameters
    $Params = @{
        Path    = $moduleSourcePath
        Recurse = $true
        Include = "*.PSSATests.*"
    }

    $TestFiles = Get-ChildItem @Params

    # Pester parameters
    $Params = @{
        Path     = $TestFiles
        PassThru = $true
    }

    # Additional parameters on Azure Pipelines agents to generate test results
    if ($env:TF_BUILD) {
        if (-not (Test-Path -Path $buildOutputPath -ErrorAction SilentlyContinue)) {
            New-Item -Path $buildOutputPath -ItemType Directory
        }
        $Timestamp = Get-date -UFormat "%Y%m%d-%H%M%S"
        $PSVersion = $PSVersionTable.PSVersion.Major
        $TestResultFile = "AnalysisResults_PS$PSVersion`_$TimeStamp.xml"
        $Params.Add("OutputFile", "$buildOutputPath\$TestResultFile")
        $Params.Add("OutputFormat", "NUnitXml")
    }

    # Invoke all tests
    $TestResults = Invoke-Pester @Params
    if ($TestResults.FailedCount -gt 0) {
        $TestResults | Format-List
        Write-Error "One or more PSScriptAnalyzer rules have been violated. Build cannot continue!"
    }
}

# Synopsis: Test the project with Pester tests
task Test {
    # Get-ChildItem parameters
    $Params = @{
        Path    = $moduleSourcePath
        Recurse = $true
        Include = "*.Tests.*"
    }

    $TestFiles = Get-ChildItem @Params

    # Pester parameters
    $Params = @{
        Path     = $TestFiles
        PassThru = $true
    }

    # Additional parameters on Azure Pipelines agents to generate test results
    if ($env:TF_BUILD) {
        if (-not (Test-Path -Path $buildOutputPath -ErrorAction SilentlyContinue)) {
            New-Item -Path $buildOutputPath -ItemType Directory
        }
        $Timestamp = Get-date -UFormat "%Y%m%d-%H%M%S"
        $PSVersion = $PSVersionTable.PSVersion.Major
        $TestResultFile = "TestResults_PS$PSVersion`_$TimeStamp.xml"
        $Params.Add("OutputFile", "$buildOutputPath\$TestResultFile")
        $Params.Add("OutputFormat", "NUnitXml")
    }

    # Invoke all tests
    $TestResults = Invoke-Pester @Params
    if ($TestResults.FailedCount -gt 0) {
        $TestResults | Format-List
        throw "One or more Pester tests have failed. Build cannot continue!"
    }
}

# Synopsis: Update the module manifest with module version and functions to export
task UpdateModuleManifest {
    #region Generating new module version

    # Using the current NuGet package version from the feed as a version base when building via Azure DevOps pipeline
    if ($env:TF_BUILD) {

        #TODO: get the current version module from the NuGet feed

        # Register a target PSRepository

        # Find and install the module from the repository
        if (Find-Module -Name $moduleName -Repository $repositoryName) {
            try {
                Install-Module -Name $moduleName -Repository $repositoryName

                # Get the largest module version
                $currentModuleVersion = (Get-Module -Name $moduleName -ListAvailable | Measure-Object -Property 'Version' -Maximum).Maximum

                # Set module version base numbers
                [int]$Major = $currentModuleVersion.Major
                [int]$Minor = $currentModuleVersion.Minor
                [int]$Build = $currentModuleVersion.Build

                # Get the count of exported module functions
                $existingFunctionsCount = (Get-Command -Module $moduleName | Measure-Object).Count
            }
            catch {
                throw "Cannot install module '$moduleName' from '$repositoryName' repository!"
            }

        }
        # In no existing module version was found, set base module version to zero
        else {
            [int]$Major = 0
            [int]$Minor = 0
            [int]$Build = 0
        }

        # Check if new public functions were added in the current build
        [int]$sourceFunctionsCount = (Get-ChildItem -Path "$moduleSourcePath\Public" -Exclude "*.Tests.*").Count
        [int]$newFunctionsCount = [System.Math]::Abs($sourceFunctionsCount - $existingFunctionsCount)

        # Increase the minor number if any new public functions have been added
        if ($newFunctionsCount -gt 0) {
            [int]$Minor = $Minor + 1
            [int]$Build = 0
        }
        # If not, just increase the build number
        else {
            [int]$Build = $Build + 1
        }
    }
    # When building locally, set module version base to 0.0.1
    else {
        [int]$Major = 0
        [int]$Minor = 0
        [int]$Build = 1

        Write-Warning "Build is running locally. Use local builds for test purpose only!"
    }

    # Update the module version object
    $newModuleVersion = New-Object -TypeName 'System.Version' -ArgumentList ($Major, $Minor, $Build)

    #endregion

    #region Generating the list of functions to be exported by module
    # Set exported functions by finding functions exported by *.psm1 file via Export-ModuleMember
    $params = @{
        Force    = $true
        Passthru = $true
        Name     = (Resolve-Path (Get-ChildItem -Path $moduleSourcePath -Filter '*.psm1')).Path
    }
    $PowerShell = [Powershell]::Create()
    [void]$PowerShell.AddScript(
        {
            Param ($Force, $Passthru, $Name)
            $module = Import-Module -Name $Name -PassThru:$Passthru -Force:$Force
            $module | Where-Object { $_.Path -notin $module.Scripts }
        }
    ).AddParameters($Params)
    $module = $PowerShell.Invoke()
    $functionsToExport = $module.ExportedFunctions.Keys

    #endregion

    #region Updating module manifest

    $moduleManifestPath = Join-Path -Path $moduleSourcePath -ChildPath "$moduleName.psd1"

    # Update-ModuleManifest parameters
    $Params = @{
        Path              = $moduleManifestPath
        ModuleVersion     = $newModuleVersion
        FunctionsToExport = $functionsToExport
    }

    # Update the manifest file
    Update-ModuleManifest @Params

    #endregion
}

# Synopsis: Update the NuGet package specification with module version
task UpdatePackageSpecification {
    # NuGet package specification
    $nuspecPath = Join-Path -Path $moduleSourcePath -ChildPath "$moduleName.nuspec"

    # Load the specification into XML object
    $xml = New-Object -TypeName 'XML'
    $xml.Load($nuspecPath)

    # Update package version
    $metadata = Select-XML -Xml $xml -XPath '//package/metadata'
    $metadata.Node.Version = $newModuleVersion

    # Save XML object back to the specification file
    $xml.Save($nuspecPath)
}

# Synopsis: Copy the module files to the target build directory
task CopyFiles {
    # Create versioned output folder
    $moduleOutputPath = Join-Path -Path $buildOutputPath -ChildPath $moduleName -AdditionalChildPath $newModuleVersion
    if (-not (Test-Path $moduleOutputPath)) {
        New-Item -Path $moduleOutputPath -ItemType Directory
    }

    # Copy-Item parameters
    $Params = @{
        Path        = "$moduleSourcePath\*"
        Destination = $moduleOutputPath
        Exclude     = "*.Tests.*", "*.PSSATests.*"
        Recurse     = $true
        Force       = $true
    }

    # Copy module files to the target build folder
    Copy-Item @Params
}

# Synopsis: Verify the code coverage by tests
task CodeCoverage {
    $acceptableCodeCoveragePercent = 60

    $path = $moduleSourcePath
    $files = Get-ChildItem $path -Recurse -Include '*.ps1', '*.psm1' -Exclude '*.Tests.ps1', '*.PSSATests.ps1'

    $Params = @{
        Path         = $path
        CodeCoverage = $files
        PassThru     = $true
        Show         = 'Summary'
    }

    # Additional parameters on Azure Pipelines agents to generate code coverage report
    if ($env:TF_BUILD) {
        if (-not (Test-Path -Path $buildOutputPath -ErrorAction SilentlyContinue)) {
            New-Item -Path $buildOutputPath -ItemType Directory
        }
        $Timestamp = Get-date -UFormat "%Y%m%d-%H%M%S"
        $PSVersion = $PSVersionTable.PSVersion.Major
        $TestResultFile = "CodeCoverageResults_PS$PSVersion`_$TimeStamp.xml"
        $Params.Add("CodeCoverageOutputFile", "$buildOutputPath\$TestResultFile")
    }

    $result = Invoke-Pester @Params

    If ( $result.CodeCoverage ) {
        $codeCoverage = $result.CodeCoverage
        $commandsFound = $codeCoverage.NumberOfCommandsAnalyzed

        # To prevent any "Attempted to divide by zero" exceptions
        If ( $commandsFound -ne 0 ) {
            $commandsExercised = $codeCoverage.NumberOfCommandsExecuted
            [System.Double]$actualCodeCoveragePercent = [Math]::Round(($commandsExercised / $commandsFound) * 100, 2)
        }
        Else {
            [System.Double]$actualCodeCoveragePercent = 0
        }
    }

    # Fail the task if the code coverage results are not acceptable
    if ($actualCodeCoveragePercent -lt $acceptableCodeCoveragePercent) {
        throw "The overall code coverage by Pester tests is $actualCodeCoveragePercent% which is less than quality gate of $acceptableCodeCoveragePercent%. Pester UpdatenewModuleVersion is: $((Get-Module -Name Pester -ListAvailable).UpdatenewModuleVersion)."
    }
}

# Synopsis: Clean up the target build directory
task Clean {
    if (Test-Path $buildOutputPath) {
        Remove-Item –Path $buildOutputPath –Recurse
    }
}