package registration

import (
	"errors"
	"net/mail"
	"strings"
)

func Email(raw string) (string, error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	a, err := mail.ParseAddress(value)
	if err != nil || a.Address != value || len(value) > 254 || !strings.Contains(value, "@") || strings.ContainsAny(value, "\r\n\x00") {
		return "", errors.New("请输入有效的电子邮件地址")
	}
	return value, nil
}
