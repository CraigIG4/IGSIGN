// IGSIGN — Mobile navigation toggle.
// Usage:
//   <mobile-menu data-menu-id="igsign-mobile-nav">
//     <button data-action="toggle">☰</button>
//   </mobile-menu>
//   <div id="igsign-mobile-nav" style="display:none;">…links…</div>

export default class extends HTMLElement {
  connectedCallback () {
    this._menu = document.getElementById(this.dataset.menuId)

    this.querySelectorAll('[data-action="toggle"]').forEach((btn) => {
      btn.addEventListener('click', () => this.toggle())
    })

    // Close the menu when a nav link inside the drawer is clicked
    if (this._menu) {
      this._menu.querySelectorAll('a').forEach((link) => {
        link.addEventListener('click', () => this.close())
      })
    }
  }

  toggle () {
    if (!this._menu) return
    const isOpen = this._menu.style.display !== 'none' && this._menu.style.display !== ''
    isOpen ? this.close() : this.open()
  }

  open () {
    if (!this._menu) return
    this._menu.style.display = 'flex'
    this.querySelector('[data-action="toggle"]')?.setAttribute('aria-expanded', 'true')
  }

  close () {
    if (!this._menu) return
    this._menu.style.display = 'none'
    this.querySelector('[data-action="toggle"]')?.setAttribute('aria-expanded', 'false')
  }
}
