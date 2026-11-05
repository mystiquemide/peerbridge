// Dev B's in-progress checkout call. The form state is turned into the
// request body here, so this file is what frontend-agent reads.

export interface CartLine {
  sku: string;
  quantity: number;
}

export interface Cart {
  totalCents: number;
  currency: string;
  lines: CartLine[];
}

export interface CheckoutBody {
  price_cents: number;
  currency: string;
  items: CartLine[];
}

// The cart the checkout page loads in development.
export const DEMO_CART: Cart = {
  totalCents: 4999,
  currency: "usd",
  lines: [{ sku: "mug", quantity: 1 }],
};

export function buildCheckoutBody(cart: Cart): CheckoutBody {
  return {
    price_cents: cart.totalCents,
    currency: cart.currency,
    items: cart.lines.map((line) => ({ sku: line.sku, quantity: line.quantity })),
  };
}

export async function submitCheckout(apiBase: string, cart: Cart): Promise<Response> {
  return fetch(`${apiBase}/v2/checkout`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(buildCheckoutBody(cart)),
  });
}
