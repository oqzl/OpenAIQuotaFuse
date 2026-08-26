# Shell tests

Run the dependency-light mocked `run` test with:

```sh
bash tests/shell/run-mocked.sh
```

The test replaces `curl` through `PATH`, so it does not require OpenAI credentials or network access. It verifies that `run` uses `/v1/responses/input_tokens`, reserves the returned input count plus `max_output_tokens`, performs inference only after quota validation, and reports actual response usage diagnostics.
