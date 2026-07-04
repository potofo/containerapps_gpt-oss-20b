# Running the Tests

This directory contains unit tests and property-based tests for each PowerShell module under `modules/` (`EnvFile.psm1`, `ResourceState.psm1`, `GpuProfile.psm1`, `NginxConfig.psm1`, `AuthDecision.psm1`, `OllamaStartup.psm1`, `DeploymentMonitor.psm1`, `ContainerAppSpec.psm1`), as well as integration tests for `deploy.ps1`/`teardown.ps1`.

The test framework used is [Pester](https://pester.dev/).

## Prerequisites

Pester must be installed. If it is not installed yet, install it as follows (PowerShell 7+ recommended).

```powershell
Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

Check the installed version:

```powershell
Get-Module -ListAvailable Pester
```

## How to Run the Tests

To run all tests under the `tests/` directory from the repository root:

```powershell
Invoke-Pester -Path ./tests
```

To see detailed output (showing each test case name):

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

To run a specific test file only (e.g. the tests for `EnvFile.psm1`):

```powershell
Invoke-Pester -Path ./tests/EnvFile.Tests.ps1
```

## Naming Conventions

- Test files are named `<ModuleName>.Tests.ps1`, matching the module under test (e.g. `EnvFile.Tests.ps1`).
- Property-based tests must reference the corresponding property number from `design.md` in a comment:
  ```powershell
  # Feature: ollama-gpt-oss-container-apps, Property {number}: {property_text}
  ```
- Property-based tests must run with at least 100 iterations of random input per property.
