# Privacy Policy — Receipts4Tax

**Last updated:** August 18, 2026

Receipts4Tax is published by **DATA TECHNOLOGY GROUP INC.** ("we", "us"), 10752 Rogueriver Bnd, Tustin, CA 92782, United States.

This policy describes what Receipts4Tax does with your information. The short version: **your receipts stay on your device, and we never receive them.**

## We operate no servers and collect nothing

Receipts4Tax has no backend. We do not run an account system, we do not have a database of users, and no receipt, image, amount, vendor, or category you enter is ever transmitted to DATA TECHNOLOGY GROUP INC.

The app contains **no analytics, advertising, tracking, or crash-reporting software** of any kind. We cannot see how you use the app, and we receive no reports about it.

## Where your data is stored

Everything the app records is stored **locally on your iPhone or iPad**:

- Receipt images and PDFs
- Extracted details — vendor, date, amount, tax, line items, category
- Your categories, settings, and display preferences

These live in the app's own storage and in a shared container used by the app and its Share Extension. Receipts are also exposed in the iOS **Files** app, under **On My iPhone → Receipts4Tax**, so you can browse, copy, or archive them yourself.

Receipts4Tax does **not** use iCloud. It has no iCloud Drive folder, no CloudKit database, and no account with us to sync to.

**Receipt images are deliberately excluded from iCloud and iTunes device backups.** The app marks its receipt folders as non-backing-up on every launch, so individual receipt images and PDFs never leave your phone through a system backup.

The one exception is a backup you make yourself: the app can produce backup archives (Settings → Archive & Backup), and those archives are stored in a separate folder that *is* included in device backups. If you have iCloud Backup enabled, an archive you have created can therefore be copied to iCloud as part of your device backup, under Apple's terms rather than ours. You can delete archives at any time from the Files app.

## AI extraction — the one time data leaves your device

To read a receipt automatically, the app sends the receipt image (or text recognized from it) to an AI provider **you choose and pay for directly**. You supply your own API key; we do not provide, proxy, or see it.

You select the provider in Settings:

| Provider | Data leaves your device? |
|---|---|
| Apple On-Device | **No** — processed entirely on your device |
| Anthropic (Claude) | Yes — sent to `api.anthropic.com` |
| OpenAI | Yes — sent to `api.openai.com` |
| Google Gemini | Yes — sent to `generativelanguage.googleapis.com` |
| Perplexity | Yes — sent to `api.perplexity.ai` |
| Microsoft Document Intelligence | Yes — sent to the Azure endpoint you configure |

When you use any provider other than Apple On-Device, **that provider's privacy policy and data-retention terms govern what happens to the receipt you send them.** We are not a party to that exchange. Please review the terms of whichever provider you enable:

- Anthropic — <https://www.anthropic.com/legal/privacy>
- OpenAI — <https://openai.com/policies/privacy-policy>
- Google — <https://policies.google.com/privacy>
- Perplexity — <https://www.perplexity.ai/hub/legal/privacy-policy>
- Microsoft — <https://privacy.microsoft.com/privacystatement>

If you would prefer that no receipt data ever leaves your device, select **Apple On-Device** extraction. It requires a device that supports Apple Intelligence.

## API keys

Any API key you enter is stored in the **iOS Keychain** on your device, in a group shared between the app and its Share Extension so both can perform extraction. Keys are sent only to the corresponding provider, and only to perform extraction you requested. They are never transmitted to us.

You can remove a stored key at any time in Settings.

## Permissions the app asks for

**Camera** — used only to photograph a receipt or bill when you choose to. Photos taken this way are saved to the app's own storage.

**Photo Library** — used only when you pick an existing image to import.

**Contacts** — optional. If you use the "Check a Bill" quick-send feature, the app asks you to pick one recipient so later shares open a pre-addressed Messages draft. Only that person's **name and phone number** are saved, only on your device, and only to pre-fill the share. The app does not read, upload, or index your contacts. You can clear the saved recipient in Settings.

Receipts4Tax does not request location, microphone, health, or tracking permissions.

## Sharing receipts

When you share a receipt or bill summary — by Messages, Mail, AirDrop, or any other option in the iOS share sheet — that content goes wherever you send it, through Apple's standard sharing system. We are not involved in and have no record of that.

## Your control over your data

- **Delete individual receipts** in the app at any time.
- **Delete everything** by deleting the app. Removing Receipts4Tax removes its stored receipts and settings from your device.
- **Export your data** from the Files app, or through the app's backup and archive features.

Because we never receive your data, there is nothing for you to request from us, and nothing for us to delete on your behalf.

## Children

Receipts4Tax is a business and personal expense tool and is not directed at children under 13. We do not knowingly collect information from children — and, as described above, we do not collect information from anyone.

## Changes

If this policy changes, we will update this page and revise the date at the top. Material changes will also be noted in the app's release notes.

## Contact

Questions about this policy:

**DATA TECHNOLOGY GROUP INC.**
10752 Rogueriver Bnd
Tustin, CA 92782
United States

Email: dtgincorp@gmail.com
