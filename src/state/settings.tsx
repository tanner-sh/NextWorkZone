import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { listen } from "@tauri-apps/api/event";
import { api, WEB_SESSION_EVENT, type Service, type Settings, type WebAccess } from "../api";

interface SettingsContextValue {
  settings: Settings | null;
  /** 设置页保存后调用，刷新全局设置。 */
  setSettings: (settings: Settings) => void;
  baseUrl: (service: Service) => string;
  /** 地址与 Token 都已配置。 */
  isReady: (service: Service) => boolean;
  /** 访问附件、图片等网页路径的方式；未知（尚未检测）时为 undefined。 */
  webAccess: (service: Service) => WebAccess | undefined;
  /** 每次网页访问状态变化时递增，用于让图片重新加载。 */
  sessionVersion: number;
  refreshSessions: () => void;
}

const SettingsContext = createContext<SettingsContextValue | null>(null);

export function SettingsProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [access, setAccess] = useState<Partial<Record<Service, WebAccess>>>({});
  const [sessionVersion, setSessionVersion] = useState(0);

  const refreshSessions = useCallback(() => {
    api.webAccessStatus().then(
      (status) => {
        setAccess(status);
        setSessionVersion((v) => v + 1);
      },
      () => {},
    );
  }, []);

  useEffect(() => {
    api.getSettings().then(setSettings, () => setSettings(null));
    const unlisten = listen(WEB_SESSION_EVENT, refreshSessions);
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, [refreshSessions]);

  // 地址或 Token 变化后重新检测网页访问方式
  const fingerprint = settings?.services.map((s) => `${s.baseUrl}|${s.hasToken}`).join(",");
  useEffect(() => {
    if (fingerprint) refreshSessions();
  }, [fingerprint, refreshSessions]);

  const find = useCallback((service: Service) => settings?.services.find((s) => s.service === service), [settings]);

  const value = useMemo<SettingsContextValue>(
    () => ({
      settings,
      setSettings,
      baseUrl: (service) => find(service)?.baseUrl ?? "",
      isReady: (service) => {
        const s = find(service);
        return Boolean(s?.baseUrl && s.hasToken);
      },
      webAccess: (service) => (service === "gitlab" ? "token" : access[service]),
      sessionVersion,
      refreshSessions,
    }),
    [settings, find, access, sessionVersion, refreshSessions],
  );

  return <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>;
}

export function useSettings(): SettingsContextValue {
  const value = useContext(SettingsContext);
  if (!value) throw new Error("useSettings 必须在 SettingsProvider 内使用");
  return value;
}
