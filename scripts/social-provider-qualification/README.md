# Social provider qualification

Print repeatable, read-only local evidence for one Content Rabbit publishing
provider: the capability matrix contract, the production secret status, the
focused handler tests, and (where they exist) the comment and DM adapter
evidence. It never reads secret values, opens a browser, or calls a social
provider.

## Usage

```sh
export CONTENT_RABBIT_REPO=/path/to/content-rabbit
./qualification-matrix.sh <provider>
```

Run `./qualification-matrix.sh` with no arguments to list the supported
providers.

The script only gathers evidence — a human still has to complete the live
console and test-account gates before marking a provider READY.
