// Ingle VS Code client. A thin launcher: it starts `inglec --lsp` (the in-tree C language server)
// over stdio and lets vscode-languageclient broker the JSON-RPC. All the intelligence lives in the
// compiler — this file only wires the process up and tells VS Code that `.ig` files are `ember`.
// (The internal VS Code language id / config namespace stay `ember`/`emberLsp` — like the C-side
// EmberRt, they are internal identifiers; only the display name, binary, and file ext are rebranded.)

const os = require("os");
const path = require("path");
const { workspace } = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

function activate(context) {
  const cfg = workspace.getConfiguration("emberLsp");
  // Defaults follow `make install` (PREFIX defaults to ~/.ingle), resolved against the user's home
  // dir so the extension is portable across machines. Override via the emberLsp.* settings.
  const command = cfg.get("serverPath") || path.join(os.homedir(), ".ingle", "bin", "inglec");
  const stdPath = cfg.get("stdPath") || path.join(os.homedir(), ".ingle", "std");

  const serverOptions = {
    command,
    args: ["--lsp"],
    // Pass INGLE_STD explicitly (belt-and-suspenders; the binary also finds std relative to itself).
    options: { env: Object.assign({}, process.env, { INGLE_STD: stdPath }) }
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "ember" }],
    synchronize: { fileEvents: workspace.createFileSystemWatcher("**/*.ig") }
  };

  client = new LanguageClient("emberLsp", "Ingle Language Server", serverOptions, clientOptions);
  client.start();
  context.subscriptions.push(client);
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
