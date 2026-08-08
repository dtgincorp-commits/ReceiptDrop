#!/usr/bin/env python3
"""
Throwaway ground-truth generator for the Check-a-Bill eval fixtures
(CHECK_A_BILL_ROADMAP.md, Phase 0.2) — and, separately, a data point for
comparing Azure Document Intelligence's prebuilt receipt model against the
on-device pipeline's accuracy.

This script is NOT shipped in the app. It calls Azure's prebuilt-receipt
model over REST, and writes one draft ground-truth JSON per input image in
the same shape ReceiptDrop's eval harness expects. Every draft still needs
manual verification before it's trusted as ground truth — Azure's model is
good, not perfect.

Setup (one-time):
  1. Create an Azure AI Document Intelligence resource in the Azure portal.
     The F0 (free) tier covers 500 pages/month, one page per request — fine
     for bill photos, which are always one page.
  2. From the resource's "Keys and Endpoint" page, copy KEY 1 and the
     Endpoint URL.
  3. Export them in your shell (do not hardcode / commit them):
       export AZURE_DI_ENDPOINT="https://<your-resource>.cognitiveservices.azure.com"
       export AZURE_DI_KEY="<key1>"

Usage:
  python3 azure_extract.py <input_dir_of_images> <output_dir_for_json>

  Every .jpg/.jpeg/.png/.heic in <input_dir> is sent to Azure; a draft
  ground-truth JSON is written to <output_dir> alongside a copy of Azure's
  raw response (…-raw.json) for debugging if the mapping looks wrong.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API_VERSION = "2024-11-30"
MODEL_ID = "prebuilt-receipt"
POLL_INTERVAL_SECONDS = 2
POLL_TIMEOUT_SECONDS = 60
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic"}


def analyze_receipt(image_path: Path, endpoint: str, key: str) -> dict:
    """Submits one image to the prebuilt-receipt model and polls for the result."""
    submit_url = (
        f"{endpoint.rstrip('/')}/documentintelligence/documentModels/"
        f"{MODEL_ID}:analyze?api-version={API_VERSION}"
    )
    body = image_path.read_bytes()
    request = urllib.request.Request(
        submit_url,
        data=body,
        method="POST",
        headers={
            "Ocp-Apim-Subscription-Key": key,
            "Content-Type": "application/octet-stream",
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            operation_location = response.headers.get("Operation-Location")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Azure submit failed ({e.code}): {e.read().decode()}") from e

    if not operation_location:
        raise RuntimeError("Azure response had no Operation-Location header")

    deadline = time.time() + POLL_TIMEOUT_SECONDS
    while time.time() < deadline:
        poll_request = urllib.request.Request(
            operation_location, headers={"Ocp-Apim-Subscription-Key": key}
        )
        with urllib.request.urlopen(poll_request) as response:
            result = json.loads(response.read())
        status = result.get("status")
        if status == "succeeded":
            return result
        if status == "failed":
            raise RuntimeError(f"Azure analysis failed: {result}")
        time.sleep(POLL_INTERVAL_SECONDS)

    raise TimeoutError(f"Azure analysis did not finish within {POLL_TIMEOUT_SECONDS}s")


def _amount(field: dict | None) -> float | None:
    if not field:
        return None
    currency = field.get("valueCurrency")
    return currency.get("amount") if currency else None


def convert_to_ground_truth(azure_result: dict) -> dict:
    """Maps Azure's analyzeResult.documents[0].fields into the roadmap's
    billNNN.json ground-truth shape (vendor, items, subtotal, tax,
    serviceCharge, total)."""
    documents = azure_result.get("analyzeResult", {}).get("documents", [])
    if not documents:
        return {"vendor": "", "items": [], "subtotal": None, "tax": None,
                 "serviceCharge": None, "total": None}

    fields = documents[0].get("fields", {})

    vendor = fields.get("MerchantName", {}).get("valueString", "")

    items = []
    for item_field in fields.get("Items", {}).get("valueArray", []):
        obj = item_field.get("valueObject", {})
        name = obj.get("Description", {}).get("valueString", "")
        quantity = obj.get("Quantity", {}).get("valueNumber", 1)
        price = _amount(obj.get("TotalPrice")) or _amount(obj.get("Price"))
        if name and price is not None:
            items.append({"name": name, "quantity": quantity, "price": price})

    return {
        "vendor": vendor,
        "items": items,
        "subtotal": _amount(fields.get("Subtotal")),
        "tax": _amount(fields.get("TotalTax")),
        "serviceCharge": _amount(fields.get("Tip")),
        "total": _amount(fields.get("Total")),
    }


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input_dir_of_images> <output_dir_for_json>")
        sys.exit(1)

    endpoint = os.environ.get("AZURE_DI_ENDPOINT")
    key = os.environ.get("AZURE_DI_KEY")
    if not endpoint or not key:
        print("Set AZURE_DI_ENDPOINT and AZURE_DI_KEY environment variables first.")
        print("See the setup instructions at the top of this script.")
        sys.exit(1)

    input_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)

    images = sorted(
        p for p in input_dir.iterdir() if p.suffix.lower() in IMAGE_EXTENSIONS
    )
    if not images:
        print(f"No images found in {input_dir} (looked for {sorted(IMAGE_EXTENSIONS)})")
        sys.exit(1)

    print(f"Found {len(images)} image(s). Calling Azure prebuilt-receipt model...")
    for image_path in images:
        stem = image_path.stem
        print(f"  {image_path.name} ...", end=" ", flush=True)
        try:
            raw = analyze_receipt(image_path, endpoint, key)
        except Exception as e:
            print(f"FAILED: {e}")
            continue

        draft = convert_to_ground_truth(raw)

        (output_dir / f"{stem}.json").write_text(json.dumps(draft, indent=2))
        (output_dir / f"{stem}-raw.json").write_text(json.dumps(raw, indent=2))
        print(f"ok — {len(draft['items'])} item(s), total={draft['total']}")

    print(f"\nDrafts written to {output_dir}/")
    print("Hand-verify every file against the actual receipt before trusting it as ground truth.")


if __name__ == "__main__":
    main()
