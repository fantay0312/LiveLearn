import { Icon } from "@iconify/react"
import { browser } from "#imports"
import { i18n } from "@/utils/i18n"
import { openOptionsPage } from "@/utils/navigation"
import { version } from "../../../package.json"
import { AISmartContext } from "./components/ai-smart-context"
import { AlwaysTranslate } from "./components/always-translate"
import LanguageOptionsSelector from "./components/language-options-selector"
import Hotkey from "./components/node-translation-hotkey-selector"
import ProvidersField from "./components/providers-field"
import { SiteControlToggle } from "./components/site-control-toggle"
import TranslateButton from "./components/translate-button"
import TranslatePromptSelector from "./components/translate-prompt-selector"
import TranslationModeSelector from "./components/translation-mode-selector"

function App() {
  return (
    <>
      <div className="flex flex-col gap-4 bg-background px-6 pt-5 pb-4">
        {/* gap-2 + a non-shrinking icon rail is what bounds the account menu:
            whatever is left of the 320px popup is its width, and a long display
            name ellipses inside that instead of pushing the icons off. */}
        <div className="flex items-center justify-between gap-2">
          <span className="text-base font-semibold">LiveLearn</span>
          <a href={browser.runtime.getURL("/livelearn.html")} target="_blank" rel="noreferrer" className="text-xs text-muted-foreground">使用指南</a>
        </div>
        <LanguageOptionsSelector />
        <ProvidersField />
        <TranslatePromptSelector />
        <div className="flex w-full items-center gap-2">
          <TranslationModeSelector />
          <TranslateButton className="min-w-0 flex-1" />
        </div>
        <SiteControlToggle />
        <AlwaysTranslate />
        <Hotkey />
        <AISmartContext />
      </div>
      <div className="flex items-center justify-between bg-neutral-200 px-2 py-1 dark:bg-neutral-800">
        <button
          type="button"
          className="flex cursor-pointer items-center gap-1 rounded-md px-2 py-1 hover:bg-neutral-300 dark:hover:bg-neutral-700"
          onClick={() => {
            void openOptionsPage()
          }}
        >
          <Icon icon="tabler:settings" className="size-4" strokeWidth={1.6} />
          <span className="text-[13px] font-medium">{i18n.t("popup.options")}</span>
        </button>
        <span className="text-sm text-neutral-500 dark:text-neutral-400">{version}</span>
        <span className="px-2 text-xs text-muted-foreground">本地扩展</span>
      </div>
    </>
  )
}

export default App
