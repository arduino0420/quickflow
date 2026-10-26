# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "pdfjs", to: "/vendor/pdfjs/6.4.299/pdf.min.mjs", preload: false
pin "pdf_ink", to: "pdf_ink.js", preload: false
pin "pdf_export", to: "pdf_export.js", preload: false
pin "pdf-lib", to: "/vendor/pdf-lib/1.17.1/pdf-lib.esm.min.js", preload: false
pin "pdf_draft", to: "pdf_draft.js", preload: false
pin "submission_confirmation", to: "submission_confirmation.js", preload: false
