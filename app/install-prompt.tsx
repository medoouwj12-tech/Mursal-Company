'use client';
import { useEffect, useState } from 'react';

type BeforeInstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
};

const DISMISS_KEY = 'mersal-install-dismissed';
const DISMISS_DAYS = 7;

function isStandalone() {
  return window.matchMedia('(display-mode: standalone)').matches || (window.navigator as unknown as { standalone?: boolean }).standalone === true;
}

function isIos() {
  const ua = window.navigator.userAgent;
  return /iPad|iPhone|iPod/.test(ua) || (ua.includes('Macintosh') && 'ontouchend' in document);
}

export default function InstallPrompt() {
  const [mounted, setMounted] = useState(false);
  const [visible, setVisible] = useState(false);
  const [ios, setIos] = useState(false);
  const [installing, setInstalling] = useState(false);
  const [promptEvent, setPromptEvent] = useState<BeforeInstallPromptEvent | null>(null);

  useEffect(() => {
    setMounted(true);
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
    if (isStandalone()) return;

    const dismissedAt = Number(localStorage.getItem(DISMISS_KEY) || 0);
    const recentlyDismissed = Date.now() - dismissedAt < DISMISS_DAYS * 24 * 60 * 60 * 1000;
    if (recentlyDismissed) return;

    const onBeforeInstall = (event: Event) => {
      event.preventDefault();
      setPromptEvent(event as BeforeInstallPromptEvent);
      setVisible(true);
    };
    const onInstalled = () => {
      setVisible(false);
      setPromptEvent(null);
    };

    window.addEventListener('beforeinstallprompt', onBeforeInstall);
    window.addEventListener('appinstalled', onInstalled);

    // iOS never fires beforeinstallprompt, so show the manual Safari steps instead.
    if (isIos()) {
      setIos(true);
      const timer = window.setTimeout(() => setVisible(true), 1500);
      return () => {
        window.clearTimeout(timer);
        window.removeEventListener('beforeinstallprompt', onBeforeInstall);
        window.removeEventListener('appinstalled', onInstalled);
      };
    }

    return () => {
      window.removeEventListener('beforeinstallprompt', onBeforeInstall);
      window.removeEventListener('appinstalled', onInstalled);
    };
  }, []);

  const dismiss = () => {
    localStorage.setItem(DISMISS_KEY, String(Date.now()));
    setVisible(false);
  };

  const install = async () => {
    if (!promptEvent) return;
    setInstalling(true);
    try {
      await promptEvent.prompt();
      const choice = await promptEvent.userChoice;
      if (choice.outcome === 'accepted') setVisible(false);
      else dismiss();
    } finally {
      setInstalling(false);
      setPromptEvent(null);
    }
  };

  if (!mounted || !visible) return null;

  return (
    <div className="fixed inset-x-3 bottom-24 z-40 mx-auto max-w-md md:bottom-5" dir="rtl">
      <div className="flex items-center gap-3 rounded-2xl border border-amber-200 bg-white/95 p-3 shadow-2xl shadow-stone-900/15 backdrop-blur">
        <img src="/icons/icon-192.png" alt="مرسال" className="h-12 w-12 shrink-0 rounded-full ring-2 ring-amber-200" />
        <div className="min-w-0 flex-1">
          <div className="text-sm font-extrabold text-stone-900">ثبّت تطبيق مرسال</div>
          <div className="mt-0.5 text-[11px] leading-5 text-stone-500">
            {ios
              ? 'من زر المشاركة في Safari اختار «إضافة إلى الشاشة الرئيسية».'
              : 'وصول أسرع وإشعارات فورية من غير ما تفتح المتصفح.'}
          </div>
        </div>
        {ios ? (
          <button onClick={dismiss} className="shrink-0 rounded-xl bg-amber-500 px-3 py-2 text-xs font-extrabold text-white">
            تمام
          </button>
        ) : (
          <button
            onClick={install}
            disabled={installing}
            className="shrink-0 rounded-xl bg-amber-500 px-4 py-2 text-xs font-extrabold text-white disabled:opacity-60"
          >
            {installing ? 'جاري…' : 'تثبيت'}
          </button>
        )}
        <button onClick={dismiss} aria-label="إغلاق" className="shrink-0 rounded-lg p-1.5 text-stone-400 hover:bg-stone-100">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
            <path d="M18 6 6 18M6 6l12 12" />
          </svg>
        </button>
      </div>
    </div>
  );
}
