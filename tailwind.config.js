module.exports = {
  plugins: [
    require('daisyui')
  ],
  daisyui: {
    themes: [
      {
        // IGSIGN brand theme — Ignition Group navy with blue accent.
        // Theme key kept as 'docuseal' to avoid hunting data-theme references across views.
        docuseal: {
          'color-scheme': 'light',
          primary: '#1a2332',     // IG deep navy
          secondary: '#2e3d54',   // IG mid navy
          accent: '#3b82f6',      // IG accent blue
          neutral: '#0f1419',     // near-black
          'base-100': '#ffffff',  // page background
          'base-200': '#f4f6f8',  // surface light
          'base-300': '#e5e9ec',  // borders / dividers
          'base-content': '#0f1419',
          '--rounded-btn': '0.5rem',
          '--tab-border': '2px',
          '--tab-radius': '.5rem'
        }
      }
    ]
  }
}
