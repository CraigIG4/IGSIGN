# frozen_string_literal: true

# Grover — headless Chrome PDF rendering for IGSIGN CAF documents.
# Uses system Chromium installed in the Docker image.
# LibreOffice is retained for DOCX→PDF conversion (CafSubmissionCreator#convert_docx).
Grover.configure do |config|
  config.options = {
    executable_path: '/usr/bin/chromium',
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      '--single-process'
    ],
    viewport: { width: 794, height: 1123 } # A4 at 96dpi
  }
end
