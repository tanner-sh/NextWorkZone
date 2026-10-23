import type { Service } from "../api";

// 自定义协议在 Windows 上以 http://<scheme>.localhost 的形式访问，其他平台为 <scheme>://localhost。
const PREFIX = navigator.userAgent.includes("Windows") ? "http://nextworkzone.localhost/" : "nextworkzone://localhost/";

/**
 * 把需要认证的系统地址（相对路径或完整地址）转换为经由 Rust 代理的地址。
 * `version` 在网页登录状态变化后改变，使之前加载失败的图片重新请求。
 */
export function assetUrl(service: Service, pathOrUrl: string, version = 0): string {
  return `${PREFIX}${service}/${encodeURIComponent(pathOrUrl)}?v=${version}`;
}

/** 判断地址是否属于某个已配置的系统，返回可交给 assetUrl 的路径。 */
export function systemPath(src: string, baseUrl: string): string | null {
  if (src.startsWith("/") && !src.startsWith("//")) return src;
  if (baseUrl && (src === baseUrl || src.startsWith(`${baseUrl}/`))) return src;
  return null;
}
