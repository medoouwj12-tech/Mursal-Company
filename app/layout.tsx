import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'مرسال | إدارة الطلبات',
  description: 'منصة مرسال للخدمات المتكاملة لإدارة الطلبات والتوصيل',
  manifest: '/manifest.webmanifest',
};
export const viewport: Viewport = { themeColor: '#f59e0b' };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="ar" dir="rtl"><body>{children}</body></html>;
}
