import { addCollection, _api } from "@iconify/react"
import icons from "@/assets/livelearn-icons.json"

let ready = false
export function ensureLocalIcons() {
  if (ready) return
  for (const collection of icons) addCollection(collection)
  // UI icons are code-bundled; an unknown/custom icon must never trigger a CDN fetch.
  _api.setFetch(async () => new Response("", { status: 404 }))
  ready = true
}
ensureLocalIcons()
