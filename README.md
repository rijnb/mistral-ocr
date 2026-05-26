# mistral-ocr

A shell script that runs [Mistral OCR](https://mistral.ai) on a local PDF or image file and writes the extracted text as Markdown, saving any embedded images alongside it.

## Requirements

- `curl`
- `jq`
- A Mistral API key with OCR access

## Configuration

Set these environment variables before running:

| Variable | Description | Example |
|---|---|---|
| `MISTRAL_OCR_API_KEY` | Your Mistral API key | `...` |
| `MISTRAL_OCR_MODEL` | Model name | `mistral-ocr-latest` |
| `MISTRAL_OCR_URL` | API endpoint | `https://api.mistral.ai/v1/ocr` |

## Usage

```bash
mistral-ocr.sh -i <input_file> [-o <output_file.md>]
```

- `-i` — input file (PDF, PNG, JPEG, GIF, WebP, or TIFF); **required**
- `-o` — output Markdown file; defaults to `<input>.md` in the same directory

### Examples

```bash
# Extract text from a PDF (writes to document.md)
mistral-ocr.sh -i document.pdf

# Specify the output path explicitly
mistral-ocr.sh -i scan.png -o output/result.md
```

## Output

- The extracted text is written as Markdown to the output file.
- Multi-page documents have pages separated by `---`.
- Embedded images are saved to `_resources/` next to the output file, and the Markdown references are rewritten to point there automatically.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Missing dependency (`curl` or `jq`) or unset env var |
| `2` | Bad arguments |
| `3` | API error |

## License

MIT — see [LICENSE.md](LICENSE.md).
