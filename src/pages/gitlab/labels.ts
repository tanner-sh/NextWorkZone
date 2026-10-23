// 合并请求和流水线状态的中文名称（问题详情等其他页面也会用到，单独放一个小文件）。

/** 合并请求的状态。 */
export const STATE_LABELS: Record<string, string> = { opened: "打开", merged: "已合并", closed: "已关闭", locked: "已锁定" };

/** 流水线的状态。 */
export const PIPELINE_LABELS: Record<string, string> = {
  success: "流水线已通过", failed: "流水线失败", running: "流水线运行中", pending: "流水线等待中", canceled: "流水线已取消", skipped: "流水线已跳过",
  manual: "流水线等待手动操作", created: "流水线已创建", scheduled: "流水线已排期", preparing: "流水线准备中", waiting_for_resource: "流水线等待资源",
};
