import { isPermissionGranted, requestPermission, sendNotification } from "@tauri-apps/plugin-notification";
import { api } from "../api";
import { MY_UNRESOLVED_JQL } from "../pages/jira/jql";

/** 我的未解决问题总数（侧边栏显示）。新分配的问题由动态提醒通知。 */
export async function countMyIssues(): Promise<number> {
  return (await api.jiraSearch(MY_UNRESOLVED_JQL, 0, 1)).total;
}

/** 发送系统通知（首次使用时请求权限）。 */
export async function notify(title: string, body: string) {
  let granted = await isPermissionGranted();
  if (!granted) granted = (await requestPermission()) === "granted";
  if (granted) sendNotification({ title, body });
}
