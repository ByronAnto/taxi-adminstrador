"use client";

import { onAuthStateChanged, User } from "firebase/auth";
import { doc, getDoc } from "firebase/firestore";
import { useRouter } from "next/navigation";
import {
  createContext,
  useContext,
  useEffect,
  useState,
  ReactNode,
} from "react";
import { getFirebase } from "./firebase";

export interface ClientProfile {
  uid: string;
  name: string;
  phone: string;
  email: string;
  associationId: string;
}

interface AuthContextValue {
  user: User | null;
  profile: ClientProfile | null;
  loading: boolean;
}

const AuthContext = createContext<AuthContextValue>({
  user: null,
  profile: null,
  loading: true,
});

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [profile, setProfile] = useState<ClientProfile | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const { auth, db } = getFirebase();
    const unsub = onAuthStateChanged(auth, async (u) => {
      setUser(u);
      if (u) {
        try {
          const snap = await getDoc(doc(db, "clients", u.uid));
          if (snap.exists()) {
            const d = snap.data();
            setProfile({
              uid: u.uid,
              name: (d.name as string) ?? "",
              phone: (d.phone as string) ?? "",
              email: (d.email as string) ?? u.email ?? "",
              associationId: (d.associationId as string) ?? "",
            });
          } else {
            setProfile(null);
          }
        } catch {
          setProfile(null);
        }
      } else {
        setProfile(null);
      }
      setLoading(false);
    });
    return () => unsub();
  }, []);

  return (
    <AuthContext.Provider value={{ user, profile, loading }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}

/** Hook que redirige a /login si no hay user autenticado. */
export function useRequireAuth() {
  const { user, loading } = useAuth();
  const router = useRouter();
  useEffect(() => {
    if (!loading && !user) router.replace("/login");
  }, [user, loading, router]);
  return { user, loading };
}
