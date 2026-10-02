import { browser } from "#imports"
import { PageLayout } from "../../components/page-layout"
export function HelpAndCommunityPage() {
  return <PageLayout title="LiveLearn 网页翻译" description="本地扩展与使用帮助">
    <p><a href={browser.runtime.getURL("/livelearn.html")}>打开本地使用指南与开源说明</a></p>
  </PageLayout>
}
