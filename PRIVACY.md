# MLX Desk Privacy

MLX Desk runs model inference on the Mac. Prompts and responses are stored locally in the user's Application Support folder and are not sent to an analytics service by the app.

Model files are downloaded from Hugging Face when the user starts a model. Hugging Face receives the normal network metadata required for that download. A gated or private model may require a user-configured Hugging Face token.

The Diagnostics export contains app/runtime state, hardware capacity, model identifiers, and recent operational events. It deliberately excludes prompt and response text. Apple MetricKit crash and hang payloads are retained locally under `Application Support/MLXDesk/Diagnostics`; MLX Desk does not upload them.

