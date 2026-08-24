// Smallest real Workspace add-on wiring: homepage card -> save API key -> validate it
// against your API with UrlFetchApp. Swap API_BASE + the validate path for your API.

var API_BASE = 'https://api.example.com/v1'; // must be in urlFetchWhitelist
var PROP_API_KEY_ = 'MY_API_KEY';

/** Homepage trigger (appsscript.json -> addOns.common.homepageTrigger.runFunction). */
function onHomepage() {
  return CardService.newCardBuilder()
    .setHeader(CardService.newCardHeader().setTitle('Connect your account'))
    .addSection(
      CardService.newCardSection()
        .addWidget(
          CardService.newTextParagraph().setText(
            'Paste your <b>API key</b>. It is stored in your user properties only.'
          )
        )
        .addWidget(
          CardService.newTextInput()
            .setFieldName('apiKey')
            .setTitle('API key')
            .setHint('Paste key here')
        )
        .addWidget(
          CardService.newTextButton()
            .setText('Save')
            .setTextButtonStyle(CardService.TextButtonStyle.FILLED)
            .setOnClickAction(CardService.newAction().setFunctionName('onSaveApiKey'))
        )
    )
    .build();
}

/** Action handler: must return an ActionResponse (not a Card). */
function onSaveApiKey(e) {
  var key = (e.formInput.apiKey || '').trim();
  if (!key) return notify_('Enter an API key first.');

  // muteHttpExceptions only covers non-2xx responses; a DNS/timeout/allow-list
  // failure still throws, so an uncaught apiFetch_ here would drop the user
  // straight into a generic Apps Script error instead of a helpful notification.
  var result;
  try {
    result = apiFetch_('/me', key); // any lightweight authenticated GET
  } catch (err) {
    return notify_('Could not reach the API: ' + err);
  }
  if (!result.ok) return notify_('Key rejected: HTTP ' + result.status);

  PropertiesService.getUserProperties().setProperty(PROP_API_KEY_, key);
  return notify_('API key saved.');
}

/**
 * Thin REST client. Needs the script.external_request scope + origin in
 * urlFetchWhitelist; muteHttpExceptions:true or non-2xx throws and hides the body.
 */
function apiFetch_(path, key) {
  var res = UrlFetchApp.fetch(API_BASE + path, {
    method: 'get',
    contentType: 'application/json',
    headers: { Authorization: 'Bearer ' + key },
    muteHttpExceptions: true,
  });
  var status = res.getResponseCode();
  return { ok: status >= 200 && status < 300, status: status, text: res.getContentText() };
}

function notify_(text) {
  return CardService.newActionResponseBuilder()
    .setNotification(CardService.newNotification().setText(text))
    .build();
}
