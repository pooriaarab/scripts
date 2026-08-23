// Smallest real Raycast-extension wiring: a Form command that reads your API key from
// extension preferences and calls your API. Swap `callApi` for your product's SDK or
// REST call. Lives at src/<name>.tsx — the filename MUST equal the command's `name` in
// package.json's `commands[]`, and the key MUST be a `type: "password"` preference.

import { Action, ActionPanel, Form, Icon, Toast, getPreferenceValues, showToast, useNavigation } from "@raycast/api";

interface ExtensionPreferences {
  apiKey: string; // declared in package.json preferences[] as type "password", required
}

export default function Command() {
  const { pop } = useNavigation();

  async function handleSubmit(values: Form.Values) {
    const content = String(values.content ?? "").trim();
    if (!content) {
      await showToast({ style: Toast.Style.Failure, title: "Content is required" });
      return;
    }

    // No implicit progress UI in Raycast — show one for any network call.
    const toast = await showToast({ style: Toast.Style.Animated, title: "Sending…" });
    try {
      const { apiKey } = getPreferenceValues<ExtensionPreferences>();
      await callApi(apiKey.trim(), { content });
      toast.style = Toast.Style.Success;
      toast.title = "Sent";
      pop(); // return to root search
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Request failed";
      toast.message = error instanceof Error ? error.message : String(error); // surface, don't swallow
    }
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm icon={Icon.Upload} title="Send" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea id="content" title="Content" placeholder="What's happening?" />
    </Form>
  );
}

async function callApi(apiKey: string, body: unknown) {
  const res = await fetch("https://api.example.com/v1/items", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`API -> ${res.status}`);
  return res.json();
}
