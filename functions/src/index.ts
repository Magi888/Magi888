/**
 * MoneySENT → Stripe PaymentIntent (Flutter `stripe_payment.dart` гэрээнд нийцнэ).
 *
 * POST JSON:
 *  - amount_cents (int)
 *  - currency (string, жишээ нь "eur")
 *  - customer_email, customer_name (сонголттой)
 *  - flow: "remittance" | "voo" (сонголттой)
 *  - metadata: object (сонголттой)
 *  - plan_id, phone (voo-д илгээгдэнэ)
 *
 * Authorization: Bearer ... — BACKEND_BEARER тохируосон үед шаардлагатай.
 *
 * Хариу: { "client_secret": "pi_..." }
 */

import { onRequest } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import Stripe from "stripe";

const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");
/** Хоосон биш бол аппын STRIPE_BACKEND_BEARER-тэй яг тааруулна. */
const backendBearer = defineString("BACKEND_BEARER", { default: "" });

const META_PREFIX = "app_";

function safeMetaKey(k: string): string {
  const s = k.replace(/[^\w-]/g, "_").slice(0, 36);
  return s.length ? `${META_PREFIX}${s}` : `${META_PREFIX}x`;
}

function safeMetaVal(v: unknown): string {
  const s = v === undefined || v === null ? "" : String(v);
  return s.slice(0, 450);
}

export const createPaymentIntent = onRequest(
  {
    cors: true,
    region: "europe-west3",
    secrets: [stripeSecretKey],
    timeoutSeconds: 30,
    memory: "256MiB",
    maxInstances: 20,
  },
  async (req, res) => {
    if (req.method === "OPTIONS") {
      res.status(204).send("");
      return;
    }

    if (req.method !== "POST") {
      res.status(405).json({ error: "Method not allowed" });
      return;
    }

    const expected = backendBearer.value().trim();
    if (expected.length > 0) {
      const auth = req.headers.authorization ?? "";
      if (auth !== `Bearer ${expected}`) {
        res.status(401).json({ error: "Unauthorized" });
        return;
      }
    }

    const body =
      typeof req.body === "object" && req.body !== null && !Array.isArray(req.body)
        ? (req.body as Record<string, unknown>)
        : {};

    const amountRaw = body.amount_cents;
    const amount =
      typeof amountRaw === "number"
        ? amountRaw
        : typeof amountRaw === "string"
          ? Number.parseInt(amountRaw, 10)
          : NaN;

    if (!Number.isFinite(amount) || !Number.isInteger(amount) || amount < 50) {
      res.status(400).json({ error: "Invalid amount_cents (min 50)" });
      return;
    }

    const currencyRaw = body.currency;
    if (typeof currencyRaw !== "string" || currencyRaw.length < 3) {
      res.status(400).json({ error: "Invalid currency" });
      return;
    }
    const currency = currencyRaw.toLowerCase().slice(0, 3);

    const metadata: Record<string, string> = {};

    const flow = body.flow;
    if (typeof flow === "string") metadata[safeMetaKey("flow")] = safeMetaVal(flow);

    const email = body.customer_email;
    if (typeof email === "string" && email.includes("@")) {
      metadata[safeMetaKey("customer_email")] = safeMetaVal(email);
    }

    const name = body.customer_name;
    if (typeof name === "string" && name.trim()) {
      metadata[safeMetaKey("customer_name")] = safeMetaVal(name.trim());
    }

    const phone = body.phone;
    if (typeof phone === "string" && phone.trim()) {
      metadata[safeMetaKey("phone")] = safeMetaVal(phone.trim());
    }

    const planId = body.plan_id;
    if (typeof planId === "string" && planId.trim()) {
      metadata[safeMetaKey("plan_id")] = safeMetaVal(planId.trim());
    }

    const extra = body.metadata;
    if (extra && typeof extra === "object" && !Array.isArray(extra)) {
      for (const [k, v] of Object.entries(extra)) {
        metadata[safeMetaKey(k)] = safeMetaVal(v);
        if (Object.keys(metadata).length >= 45) break;
      }
    }

    try {
      const stripe = new Stripe(stripeSecretKey.value());

      const pi = await stripe.paymentIntents.create({
        amount,
        currency,
        // Klarna зэрэг redirect урсгал + Dashboard-д идэвхтэй буй бүх аргууд (card, Google Pay, …)
        automatic_payment_methods: { enabled: true, allow_redirects: "always" },
        metadata,
        receipt_email:
          typeof email === "string" && email.includes("@") ? email.trim() : undefined,
        description:
          typeof flow === "string"
            ? `MoneySENT · ${flow}`
            : "MoneySENT payment",
      });

      res.status(200).json({ client_secret: pi.client_secret });
    } catch (e: unknown) {
      logger.error("Stripe PaymentIntent failed", e);
      const msg = e instanceof Error ? e.message : "Stripe error";
      res.status(502).json({ error: msg });
    }
  },
);
