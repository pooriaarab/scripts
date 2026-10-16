# eval-matrix and eval-analyze failure modes

`eval-matrix` runs a grid of benchmark package versions against models and writes one JSON report per cell. `eval-analyze` reads the reports and computes the preregistered comparisons. Neither tool decides what to claim.

The tests in `eval-matrix.test.sh` and `eval-analyze.test.sh` cover each row marked "tested". They use a fake benchmark program. No network.

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | The plan file is missing or has no packages. | Exit 2 with a message. Run nothing. | yes |
| 2 | A cell already has a report. | Skip it. A re-run costs nothing. | yes |
| 3 | A cell exits non-zero or prints bad JSON. | Retry once. Then write a `.fail` file with the error text, count the cell as missing, and go on. | yes |
| 4 | A report has no numeric `mean`. | Treat it as a failure (row 3). Never write a zero. | yes |
| 5 | The spending cap is reached in the middle of a model. | Stop launching cells. Write a `STOPPED` file naming the model and the spend. The analyzer drops that model for every package. | yes |
| 6 | The credit check says less than the reserve is left. | Stop before the next model. | no, needs the network |
| 7 | Two workers write the same file. | Each cell has one path and one writer. Write to a temp name, then rename. | yes |
| 8 | The ledger is not complete after a crash. | Rebuild it from the report files. The report files are the source of truth. | yes |
| 9 | A package version cannot be installed. | Every cell of that version is missing, with the install error. | yes |
| 10 | The analyzer meets a model with missing cells. | Drop that model from every comparison. List it under "dropped". | yes |
| 11 | The analyzer meets a package with only one version. | Leave it out of the paired tests. List it. | yes |
| 12 | All differences are ties. | Report the sign test as not computable, with the count of ties. Do not report p = 1. | yes |
| 13 | The same input gives different bootstrap output. | The bootstrap uses a fixed seed from the plan. Same input, same output. | yes |
| 14 | A secret ends up in a file. | Keys come from the environment only. A report and the ledger never hold a key. The test greps for the test key. | yes |
| 15 | Hosted model behavior changes between runs. | The tool records the date, the model id and the version in the ledger. It cannot freeze the provider. The paper says so. | no, a human rule |
