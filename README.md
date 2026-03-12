# RAVLs Optimization Engine

This repository contains a focused distribution of **RAVLs Optimization Engine**, including deployment templates, runbooks, SQL model scripts, and workbook assets.

## What’s included

- `src/optimization-engine/azuredeploy.bicep` and `azuredeploy-nested.bicep`
- Deployment and operations scripts in `src/optimization-engine/*.ps1`
- Automation runbooks in `src/optimization-engine/runbooks/`
- SQL model scripts in `src/optimization-engine/model/`
- Workbook definitions in `src/optimization-engine/views/workbooks/`

## Quick start

Run the deployment script from the optimization engine folder:

- `pwsh -File ./src/optimization-engine/Deploy-AzureOptimizationEngine.ps1`

## License

This repository is distributed under the [MIT license](LICENSE).
