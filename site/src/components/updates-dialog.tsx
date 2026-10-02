"use client";

import * as React from "react";
import { FormDialog, FormDialogConfig } from "./form-dialog";

interface UpdatesDialogProps {
  children: React.ReactNode;
}

const updatesConfig: FormDialogConfig = {
  title: "Stay updated on the project",
  description:
    "An occasional email about releases, the app, and changes to the sync protocol or the self-hosted stack. Nothing else.",
  successTitle: "You're signed up",
  successDescription:
    "We'll email you when there is a release, a protocol change, or news about the app.",
  submitLabel: "Sign Up",
  submittingLabel: "Signing up...",
  fields: [
    {
      id: "name",
      label: "Name",
      type: "text",
      placeholder: "Your name",
      required: true,
    },
    {
      id: "email",
      label: "Email",
      type: "email",
      placeholder: "you@example.com",
      required: true,
    },
  ],
  hiddenFields: {
    source: "project-updates",
  },
};

export function UpdatesDialog({ children }: UpdatesDialogProps) {
  return <FormDialog config={updatesConfig}>{children}</FormDialog>;
}
