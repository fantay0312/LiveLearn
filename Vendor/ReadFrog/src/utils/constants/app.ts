import { browser } from "#imports"

export const APP_NAME = "LiveLearn"
const manifest = browser.runtime.getManifest()
export const EXTENSION_VERSION = manifest.version
