// Package email provides an interface and implementations for sending
// transactional emails (OTP verification, and future emails).
package email

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"strings"
	"text/template"

	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sesv2"
	"github.com/aws/aws-sdk-go-v2/service/sesv2/types"
)

// Message is a transactional email. The From address is fixed by the sender
// (SESSenderConfig.From), so it is not part of the message.
type Message struct {
	To      string
	Subject string
	Text    string // plain-text body; required (iOS reads the OTP from here)
	HTML    string // optional HTML body
}

// Sender sends a transactional email.
type Sender interface {
	Send(ctx context.Context, msg Message) error
}

// otpTemplateData is the data passed to the OTP email templates.
type otpTemplateData struct {
	Code string
}

const otpEmailSubject = "Your verification code"

// defaultOTPTemplate is the plain-text OTP body. The code MUST be on its own
// line so iOS .oneTimeCode autofill detects it.
const defaultOTPTextTemplate = `Your verification code is:
{{.Code}}
`

// defaultOTPHTMLTemplate is a simple, unbranded HTML OTP body.
const defaultOTPHTMLTemplate = `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:16px;color:#111;">
  <p>Your verification code is:</p>
  <p style="font-size:32px;letter-spacing:4px;font-family:monospace;">{{.Code}}</p>
</body>
</html>
`

// Package-level OTP templates. Defaults are parsed at init; NewSender applies
// env overrides (OTP_EMAIL_TEMPLATE / OTP_EMAIL_HTML_TEMPLATE) at startup.
var (
	otpTextTmpl = template.Must(template.New("otp-text").Parse(defaultOTPTextTemplate))
	otpHTMLTmpl = template.Must(template.New("otp-html").Parse(defaultOTPHTMLTemplate))
)

// parseOTPTemplate returns a parsed template, using override when non-empty
// and the fallback otherwise. Returns an error if the override is malformed.
func parseOTPTemplate(name, override, fallback string) (*template.Template, error) {
	src := fallback
	if override != "" {
		src = override
	}
	return template.New(name).Parse(src)
}

// setOTPTemplates applies env-provided OTP template overrides. It is called
// once at startup from NewSender.
func setOTPTemplates(textOverride, htmlOverride string) error {
	tt, err := parseOTPTemplate("otp-text", textOverride, defaultOTPTextTemplate)
	if err != nil {
		return fmt.Errorf("parse OTP text template: %w", err)
	}
	ht, err := parseOTPTemplate("otp-html", htmlOverride, defaultOTPHTMLTemplate)
	if err != nil {
		return fmt.Errorf("parse OTP HTML template: %w", err)
	}
	otpTextTmpl = tt
	otpHTMLTmpl = ht
	return nil
}

// NewOTPMessage renders the OTP templates into a Message ready to send.
// Template execution against otpTemplateData cannot fail for the parsed
// templates above (Code is a plain string), but an error is logged rather
// than swallowed so a future template change surfaces loudly.
func NewOTPMessage(to, code string) Message {
	data := otpTemplateData{Code: code}

	var textBuf, htmlBuf bytes.Buffer
	if err := otpTextTmpl.Execute(&textBuf, data); err != nil {
		slog.Error("render OTP text template", "error", err)
	}
	if err := otpHTMLTmpl.Execute(&htmlBuf, data); err != nil {
		slog.Error("render OTP HTML template", "error", err)
	}

	return Message{
		To:      to,
		Subject: otpEmailSubject,
		Text:    textBuf.String(),
		HTML:    htmlBuf.String(),
	}
}

// inviteEmailSubject is the subject for household invitation emails.
const inviteEmailSubject = "You've been invited to a Shunik household"

// NewInviteMessage builds a household invitation email. The token rides in
// the plain-text body (no autofill contract — this is not an OTP).
func NewInviteMessage(to, token string) Message {
	return Message{
		To:      to,
		Subject: inviteEmailSubject,
		Text: `Someone invited you to share their Shunik household — pets, care schedules, and documents, together.

Open Shunik, sign in, and accept the invitation with this token:
` + token + `

The token expires in 7 days. If you weren't expecting this, ignore it.
`,
	}
}

// ---------- ConsoleSender ----------

// ConsoleSender prints emails to stdout (for development/testing).
type ConsoleSender struct {
	logger *slog.Logger
}

// NewConsoleSender creates a new ConsoleSender.
func NewConsoleSender(logger *slog.Logger) *ConsoleSender {
	return &ConsoleSender{logger: logger}
}

// Send prints the email to stdout.
func (s *ConsoleSender) Send(_ context.Context, msg Message) error {
	s.logger.Info("sending email", "to", msg.To, "subject", msg.Subject)
	fmt.Printf("To: %s\nSubject: %s\n\n%s\n", msg.To, msg.Subject, msg.Text)
	return nil
}

// ---------- SESSender ----------

// sesAPI wraps the single sesv2.Client method we use, so SESSender is
// unit-testable with a fake.
type sesAPI interface {
	SendEmail(ctx context.Context, params *sesv2.SendEmailInput, optFns ...func(*sesv2.Options)) (*sesv2.SendEmailOutput, error)
}

// SESSender sends emails via the AWS SES v2 API.
type SESSender struct {
	client sesAPI
	from   string
	logger *slog.Logger
}

// SESSenderConfig holds configuration for SESSender.
type SESSenderConfig struct {
	AccessKeyID     string
	SecretAccessKey string
	Region          string
	From            string
	Logger          *slog.Logger
}

// NewSESSender creates a new SESSender. All fields are required.
func NewSESSender(cfg SESSenderConfig) (*SESSender, error) {
	var missing []string
	if cfg.AccessKeyID == "" {
		missing = append(missing, "AWS_ACCESS_KEY_ID")
	}
	if cfg.SecretAccessKey == "" {
		missing = append(missing, "AWS_SECRET_ACCESS_KEY")
	}
	if cfg.Region == "" {
		missing = append(missing, "AWS_REGION")
	}
	if cfg.From == "" {
		missing = append(missing, "SES_FROM")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("missing required SES config: %s", strings.Join(missing, ", "))
	}

	client := sesv2.New(sesv2.Options{
		Region:      cfg.Region,
		Credentials: credentials.NewStaticCredentialsProvider(cfg.AccessKeyID, cfg.SecretAccessKey, ""),
	})

	return &SESSender{
		client: client,
		from:   cfg.From,
		logger: cfg.Logger,
	}, nil
}

// Send sends an email via the AWS SES v2 API.
func (s *SESSender) Send(ctx context.Context, msg Message) error {
	input := &sesv2.SendEmailInput{
		FromEmailAddress: &s.from,
		Destination: &types.Destination{
			ToAddresses: []string{msg.To},
		},
		Content: &types.EmailContent{
			Simple: &types.Message{
				Subject: &types.Content{Data: &msg.Subject},
				Body: &types.Body{
					Text: &types.Content{Data: &msg.Text},
				},
			},
		},
	}
	if msg.HTML != "" {
		input.Content.Simple.Body.Html = &types.Content{Data: &msg.HTML}
	}

	if _, err := s.client.SendEmail(ctx, input); err != nil {
		return fmt.Errorf("send via SES: %w", err)
	}

	s.logger.Info("email sent via SES", "to", msg.To)
	return nil
}

// ---------- Factory ----------

// SenderConfig holds configuration for selecting and constructing a Sender.
type SenderConfig struct {
	Backend              string // "console" (default) or "ses"
	AWSAccessKeyID       string
	AWSSecretAccessKey   string
	AWSRegion            string
	SESFrom              string
	OTPEmailTextTemplate string
	OTPEmailHTMLTemplate string
	Logger               *slog.Logger
}

// NewSender creates the appropriate Sender based on Backend. Supported values:
// "console" (default) and "ses". Misconfiguration (malformed template
// overrides, incomplete SES credentials) is returned as an error ALONGSIDE a
// console fallback, so the caller must acknowledge it explicitly instead of
// silently running without real email delivery.
func NewSender(cfg SenderConfig) (Sender, error) {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}

	if err := setOTPTemplates(cfg.OTPEmailTextTemplate, cfg.OTPEmailHTMLTemplate); err != nil {
		return NewConsoleSender(logger), fmt.Errorf("new sender: %w", err)
	}

	switch strings.ToLower(cfg.Backend) {
	case "ses":
		s, err := NewSESSender(SESSenderConfig{
			AccessKeyID:     cfg.AWSAccessKeyID,
			SecretAccessKey: cfg.AWSSecretAccessKey,
			Region:          cfg.AWSRegion,
			From:            cfg.SESFrom,
			Logger:          logger,
		})
		if err != nil {
			return NewConsoleSender(logger), fmt.Errorf("new sender: %w", err)
		}
		return s, nil
	default:
		return NewConsoleSender(logger), nil
	}
}
