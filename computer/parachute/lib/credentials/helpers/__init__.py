"""
Built-in credential helpers.

Each helper extends CredentialProvider with a manifest that describes
its setup fields, capabilities, and health check. The broker loads
helpers from config and the API exposes manifests to the app.
"""
