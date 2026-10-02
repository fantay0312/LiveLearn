import type { Theme } from "@/types/config/theme"
import { browser } from "#imports"

export function getLobeIconsCDNUrlFn(iconSlug: string) {
  return (theme: Theme = "light") => {
    return browser.runtime.getURL(`/provider-icons/${theme}/${iconSlug}.webp`)
  }
}
