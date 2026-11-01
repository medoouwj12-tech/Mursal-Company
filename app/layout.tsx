import type { Metadata, Viewport } from 'next';
import './globals.css';
import InstallPrompt from './install-prompt';

export const metadata: Metadata = {
  title: 'مرسال | إدارة الطلبات',
  description: 'منصة مرسال للخدمات المتكاملة لإدارة الطلبات والتوصيل',
  manifest: '/manifest.webmanifest',
  applicationName: 'مرسال',
  appleWebApp: { capable: true, statusBarStyle: 'default', title: 'مرسال' },
  icons: {
    icon: [
      { url: '/icons/favicon-32.png', sizes: '32x32', type: 'image/png' },
      { url: '/icons/icon-192.png', sizes: '192x192', type: 'image/png' },
    ],
    apple: [{ url: '/icons/apple-touch-icon.png', sizes: '180x180', type: 'image/png' }],
  },
};
export const viewport: Viewport = { themeColor: '#f59e0b' };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ar" dir="rtl">
      <body>
        {children}
        <InstallPrompt />
      </body>
    </html>
  );
}
