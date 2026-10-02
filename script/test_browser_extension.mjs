// Run with PLAYWRIGHT_MODULE set to a Playwright ESM entrypoint if not installed locally.
// The browser profile, fixture text and service responses are test-owned. No user profile.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const live = process.env.LIVE_TRANSLATION === "1";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = path.join(root, "tmp/browser-translation", live ? "e2e-live" : "e2e");
await fs.mkdir(output, { recursive: true });
const profile = await fs.mkdtemp(path.join(output, "profile-"));
const extension = path.join(root, "Vendor/ReadFrog/.output/chrome-mv3");
const metadata = JSON.parse(await fs.readFile(path.join(root, "build/BrowserExtension/package.json")));
const fixture = `<!doctype html><html lang="en"><meta charset="utf-8"><title>LiveLearn reading fixture</title>
<style>body{font:20px/1.7 system-ui;max-width:760px;margin:70px auto;padding:20px}p{margin:30px 0}textarea{width:100%;height:80px}</style>
<main><h1>Curiosity opens new worlds</h1><p id="first">Learning a new language helps us understand different perspectives.</p>
<p id="second">Every small discovery makes the world a little more interesting.</p>
<pre>const untouched = "Do not translate code";</pre><textarea aria-label="Editable text">Keep editable content unchanged.</textarea></main></html>`;
const server = http.createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); res.end(fixture);
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const baseURL = `http://127.0.0.1:${server.address().port}`;
const requests = [];
const serviceCalls = [];
let context;
try {
  context = await chromium.launchPersistentContext(profile, {
    channel: "chromium", headless: true, locale: "zh-CN", viewport: { width: 1120, height: 850 },
    args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
  });
  context.on("request", request => { if (/^https?:/.test(request.url())) requests.push(request.url()); });
  await context.route("https://edge.microsoft.com/translate/translatetext**", async route => {
    const texts = JSON.parse(route.request().postData());
    serviceCalls.push(...texts);
    if (live) return route.continue();
    await route.fulfill({ contentType: "application/json", body: JSON.stringify(texts.map(text => ({
      translations: [{ to: "zh-Hans", text: "测试译文：" + text }],
    }))) });
  });
  const worker = context.serviceWorkers()[0] || await context.waitForEvent("serviceworker");
  assert(worker.url().includes(metadata.extensionID));
  const guide = await context.newPage();
  await guide.goto(`chrome-extension://${metadata.extensionID}/livelearn.html`);
  await guide.getByRole("heading", { name: "把世界，读成双语。" }).waitFor();
  await guide.screenshot({ path: path.join(output, "guide-light.png"), fullPage: true });
  await guide.emulateMedia({ colorScheme: "dark" });
  await guide.screenshot({ path: path.join(output, "guide-dark.png"), fullPage: true });
  await guide.setViewportSize({ width: 390, height: 844 });
  await guide.screenshot({ path: path.join(output, "guide-mobile.png"), fullPage: true });
  const options = await context.newPage();
  await options.goto(`chrome-extension://${metadata.extensionID}/options.html#/page-translation`);
  await options.getByText("LiveLearn", { exact: true }).first().waitFor();
  await options.getByRole("heading", { name: "网页翻译", exact: true }).waitFor();
  await options.screenshot({ path: path.join(output, "options.png"), fullPage: true });
  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${metadata.extensionID}/popup.html`);
  await popup.getByText("LiveLearn", { exact: true }).waitFor();
  await popup.screenshot({ path: path.join(output, "popup.png") });
  assert.equal(requests.filter(url => /readfrog|posthog|iconify|npmmirror/.test(url)).length, 0,
    "Opening local extension UI must not query hosted accounts, telemetry, or image CDNs");

  const page = await context.newPage();
  await page.goto(baseURL);
  await page.getByTestId("floating-main-button").waitFor();
  await page.getByTestId("floating-main-button").click();
  await page.waitForFunction(() => /\p{Script=Han}/u.test(document.querySelector("#first").textContent), null, { timeout: 30000 });
  assert.equal(await page.locator("#first").evaluate(el => el.firstChild.textContent), "Learning a new language helps us understand different perspectives.");
  assert.equal(await page.locator("pre").textContent(), 'const untouched = "Do not translate code";');
  assert.equal(await page.locator("textarea").inputValue(), "Keep editable content unchanged.");
  await page.screenshot({ path: path.join(output, "bilingual.png"), fullPage: true });
  await page.evaluate(() => {
    const p = document.createElement("p"); p.textContent = "A dynamically inserted paragraph should also be translated.";
    document.querySelector("main").append(p);
  });
  await page.waitForFunction(() => /\p{Script=Han}/u.test(document.querySelector("main > p:last-child").textContent), null, { timeout: 30000 });
  await page.keyboard.press("Alt+e");
  await page.waitForFunction(() => !/\p{Script=Han}/u.test(document.querySelector("#first").textContent));
  assert.equal(await page.locator("#first").textContent(), "Learning a new language helps us understand different perspectives.");
  assert(serviceCalls.length >= 3);
  const config = await worker.evaluate(async () => (await chrome.storage.local.get("config")).config);
  assert(config);
  await worker.evaluate(async () => {
    const { config } = await chrome.storage.local.get("config");
    await chrome.storage.local.set({ config: { ...config, uiLanguage: "en" } });
  });
  await context.close();
  context = await chromium.launchPersistentContext(profile, {
    channel: "chromium", headless: true,
    args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
  });
  const resumed = context.serviceWorkers()[0] || await context.waitForEvent("serviceworker");
  assert.equal(await resumed.evaluate(async () => (await chrome.storage.local.get("config")).config.uiLanguage), "en");
  await fs.writeFile(path.join(output, "result.json"), JSON.stringify({
    ok: true, extensionID: metadata.extensionID, serviceCalls: serviceCalls.length,
    forbiddenRequests: requests.filter(url => /readfrog|posthog|iconify|npmmirror/.test(url)),
    checks: ["local-guide", "options", "popup", "bilingual", "preserve-original", "skip-code-and-input", "dynamic-content", "restore", "settings-after-browser-restart"],
    translation: live ? "live Microsoft translation of test fixture" : "deterministic service fixture, not live provider quality",
  }, null, 2));
  console.log("Browser extension E2E passed");
} catch (error) {
  await fs.writeFile(path.join(output, "failure.txt"), String(error.stack || error));
  if (context) for (const [index, page] of context.pages().entries()) {
    await page.screenshot({ path: path.join(output, `failure-${index}.png`) }).catch(() => {});
    await fs.writeFile(path.join(output, `failure-${index}.txt`), (await page.locator("body").innerText().catch(() => "")));
  }
  throw error;
} finally {
  await context?.close();
  await new Promise(resolve => server.close(resolve));
}
