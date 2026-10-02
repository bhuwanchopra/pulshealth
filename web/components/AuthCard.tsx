// The card the sign-in and invite pages are built in: the brand, a title,
// an optional error or notice, and the form.
import { BrandMark } from "./BrandMark";

export function AuthCard({
  title,
  subtitle,
  error,
  notice,
  children,
}: {
  title: string;
  subtitle?: React.ReactNode;
  error?: string | null;
  notice?: string | null;
  children?: React.ReactNode;
}) {
  return (
    <div className="panel auth-card rise">
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 22 }}>
        <BrandMark size={24} />
        <span className="brand-name">PulsHealth</span>
      </div>
      <h1 style={{ margin: 0, fontSize: 24, fontWeight: 600, letterSpacing: "-0.02em" }}>{title}</h1>
      {subtitle && <p style={{ margin: "8px 0 20px", color: "var(--muted)", fontSize: 14, lineHeight: 1.5 }}>{subtitle}</p>}
      {!subtitle && <div style={{ height: 18 }} />}
      {error && (
        <div className="form-message error" role="alert">
          {error}
        </div>
      )}
      {notice && (
        <div className="form-message notice" role="status">
          {notice}
        </div>
      )}
      {children}
    </div>
  );
}
