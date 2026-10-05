import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { Button } from "@/components/ui/button";

describe("Button", () => {
  it("renders its children", () => {
    render(<Button>Run Attack</Button>);
    expect(screen.getByRole("button", { name: "Run Attack" })).toBeInTheDocument();
  });

  it("does not fire onClick while disabled", async () => {
    let clicked = false;
    render(
      <Button disabled onClick={() => (clicked = true)}>
        Run Attack
      </Button>,
    );
    const button = screen.getByRole("button", { name: "Run Attack" });
    expect(button).toBeDisabled();
    button.click();
    expect(clicked).toBe(false);
  });
});