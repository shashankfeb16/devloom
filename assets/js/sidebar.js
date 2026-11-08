const storageKey = "devloom:sidebar-collapsed"
const toggleSelector = "[data-sidebar-toggle]"
let initialized = false

export function initializeSidebar() {
  if (initialized) return
  initialized = true

  const root = document.documentElement

  const syncToggles = () => {
    const collapsed = root.dataset.sidebarCollapsed === "true"
    const label = collapsed ? "Expand sidebar" : "Collapse sidebar"

    document.querySelectorAll(toggleSelector).forEach(button => {
      button.setAttribute("aria-expanded", String(!collapsed))
      button.setAttribute("aria-label", label)
      button.setAttribute("title", label)
    })
  }

  const setCollapsed = (collapsed, persist = false) => {
    root.dataset.sidebarCollapsed = String(collapsed)
    syncToggles()

    if (persist) {
      try {
        localStorage.setItem(storageKey, String(collapsed))
      } catch (_) { /* The toggle still works when browser storage is unavailable. */ }
    }
  }

  let collapsed = false
  try {
    collapsed = localStorage.getItem(storageKey) === "true"
  } catch (_) { /* Start expanded when browser storage is unavailable. */ }
  setCollapsed(collapsed)

  document.addEventListener("click", event => {
    const button = event.target instanceof Element && event.target.closest(toggleSelector)
    if (!button) return

    event.preventDefault()
    setCollapsed(root.dataset.sidebarCollapsed !== "true", true)
  })

  window.addEventListener("storage", event => {
    if (event.key === storageKey || event.key === null) {
      setCollapsed(event.key === storageKey && event.newValue === "true")
    }
  })

  // The preference lives outside LiveView's DOM. Refresh the accessible button
  // state when navigation introduces a newly rendered application shell.
  window.addEventListener("phx:page-loading-stop", syncToggles)

  const observeNavigation = () => {
    syncToggles()
    new MutationObserver(records => {
      const addedToggle = records.some(record => [...record.addedNodes].some(node =>
        node instanceof Element && (node.matches(toggleSelector) || node.querySelector(toggleSelector))
      ))
      if (addedToggle) syncToggles()
    }).observe(document.body, {childList: true, subtree: true})
  }

  if (document.body) {
    observeNavigation()
  } else {
    document.addEventListener("DOMContentLoaded", observeNavigation, {once: true})
  }
}
