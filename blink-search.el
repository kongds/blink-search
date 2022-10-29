;;; blink-search.el --- Blink search  -*- lexical-binding: t; -*-

;; Filename: blink-search.el
;; Description: Blink search
;; Author: Andy Stewart <lazycat.manatee@gmail.com>
;; Maintainer: Andy Stewart <lazycat.manatee@gmail.com>
;; Copyright (C) 2022, Andy Stewart, all rights reserved.
;; Created: 2022-10-23 15:23:53 +0800
;; Version: 0.1
;; Last-Updated: 2022-10-23 15:23:53 +0800
;;           By: Andy Stewart
;; URL: https://github.com/manateelazycat/blink-search
;; Keywords:
;; Compatibility: emacs-version >= 28
;; Package-Requires: ((emacs "28") (posframe "1.1.7") (markdown-mode "2.6-dev"))
;;
;; Features that might be required by this library:
;;
;; Please check README
;;

;;; This file is NOT part of GNU Emacs

;;; License
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; Blink-Search
;;

;;; Installation:
;;
;; Please check README
;;

;;; Customize:
;;
;;
;;
;; All of the above can customize by:
;;      M-x customize-group RET blink-search RET
;;

;;; Change log:
;;
;;

;;; Acknowledgements:
;;
;;
;;

;;; TODO
;;
;;
;;

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)

(require 'blink-search-epc)

(require 'recentf)

(recentf-mode 1)

(defgroup blink-search nil
  "Blink-Search group."
  :group 'applications)

(defvar blink-search-server nil
  "The Blink-Search Server.")

(defvar blink-search-python-file (expand-file-name "blink_search.py" (file-name-directory load-file-name)))

(defvar blink-search-server-port nil)

(defun blink-search--start-epc-server ()
  "Function to start the EPC server."
  (unless (process-live-p blink-search-server)
    (setq blink-search-server
          (blink-search-epc-server-start
           (lambda (mngr)
             (let ((mngr mngr))
               (blink-search-epc-define-method mngr 'eval-in-emacs 'blink-search--eval-in-emacs-func)
               (blink-search-epc-define-method mngr 'get-emacs-var 'blink-search--get-emacs-var-func)
               (blink-search-epc-define-method mngr 'get-emacs-vars 'blink-search--get-emacs-vars-func)
               ))))
    (if blink-search-server
        (setq blink-search-server-port (process-contact blink-search-server :service))
      (error "[Blink-Search] blink-search-server failed to start")))
  blink-search-server)

(defun blink-search--eval-in-emacs-func (sexp-string)
  (eval (read sexp-string))
  ;; Return nil to avoid epc error `Got too many arguments in the reply'.
  nil)

(defun blink-search--get-emacs-var-func (var-name)
  (let* ((var-symbol (intern var-name))
         (var-value (symbol-value var-symbol))
         ;; We need convert result of booleanp to string.
         ;; Otherwise, python-epc will convert all `nil' to [] at Python side.
         (var-is-bool (prin1-to-string (booleanp var-value))))
    (list var-value var-is-bool)))

(defun blink-search--get-emacs-vars-func (&rest vars)
  (mapcar #'blink-search--get-emacs-var-func vars))

(defvar blink-search-epc-process nil)

(defvar blink-search-internal-process nil)
(defvar blink-search-internal-process-prog nil)
(defvar blink-search-internal-process-args nil)

(defcustom blink-search-name "*blink-search*"
  "Name of Blink-Search buffer."
  :type 'string)

(defcustom blink-search-python-command (if (memq system-type '(cygwin windows-nt ms-dos)) "python.exe" "python3")
  "The Python interpreter used to run lsp_bridge.py."
  :type 'string)

(defcustom blink-search-enable-debug nil
  "If you got segfault error, please turn this option.
Then Blink-Search will start by gdb, please send new issue with `*blink-search*' buffer content when next crash."
  :type 'boolean)

(defcustom blink-search-enable-log nil
  "Enable this option to print log message in `*blink-search*' buffer, default only print message header."
  :type 'boolean)

(defun blink-search-call-async (method &rest args)
  "Call Python EPC function METHOD and ARGS asynchronously."
  (blink-search-deferred-chain
   (blink-search-epc-call-deferred blink-search-epc-process (read method) args)))

(defvar blink-search-is-starting nil)

(defun blink-search-restart-process ()
  "Stop and restart Blink-Search process."
  (interactive)
  (setq blink-search-is-starting nil)

  (blink-search-kill-process)
  (blink-search-start-process)
  (message "[Blink-Search] Process restarted."))

(defun blink-search-start-process ()
  "Start Blink-Search process if it isn't started."
  (setq blink-search-is-starting t)
  (unless (blink-search-epc-live-p blink-search-epc-process)
    ;; start epc server and set `blink-search-server-port'
    (blink-search--start-epc-server)
    (let* ((blink-search-args (append
                               (list blink-search-python-file)
                               (list (number-to-string blink-search-server-port))
                               )))

      ;; Set process arguments.
      (if blink-search-enable-debug
          (progn
            (setq blink-search-internal-process-prog "gdb")
            (setq blink-search-internal-process-args (append (list "-batch" "-ex" "run" "-ex" "bt" "--args" blink-search-python-command) blink-search-args)))
        (setq blink-search-internal-process-prog blink-search-python-command)
        (setq blink-search-internal-process-args blink-search-args))

      ;; Start python process.
      (let ((process-connection-type (not (blink-search--called-from-wsl-on-windows-p))))
        (setq blink-search-internal-process
              (apply 'start-process
                     blink-search-name blink-search-name
                     blink-search-internal-process-prog blink-search-internal-process-args)))
      (set-process-query-on-exit-flag blink-search-internal-process nil))))

(defun blink-search--called-from-wsl-on-windows-p ()
  "Check whether blink-search is called by Emacs on WSL and is running on Windows."
  (and (eq system-type 'gnu/linux)
       (string-match-p ".exe" blink-search-python-command)))

(defvar blink-search-stop-process-hook nil)

(defun blink-search-kill-process ()
  "Stop Blink-Search process and kill all Blink-Search buffers."
  (interactive)

  ;; Run stop process hooks.
  (run-hooks 'blink-search-stop-process-hook)

  ;; Kill process after kill buffer, make application can save session data.
  (blink-search--kill-python-process)

  (blink-search-stop-elisp-symbol-update)
  (blink-search-stop-recent-file-update)
  )

(add-hook 'kill-emacs-hook #'blink-search-kill-process)

(defun blink-search--kill-python-process ()
  "Kill Blink-Search background python process."
  (when (blink-search-epc-live-p blink-search-epc-process)
    ;; Cleanup before exit Blink-Search server process.
    (blink-search-call-async "cleanup")
    ;; Delete Blink-Search server process.
    (blink-search-epc-stop-epc blink-search-epc-process)
    ;; Kill *blink-search* buffer.
    (when (get-buffer blink-search-name)
      (kill-buffer blink-search-name))
    (setq blink-search-epc-process nil)
    (message "[Blink-Search] Process terminated.")))

(defun blink-search--first-start (blink-search-epc-port)
  "Call `blink-search--open-internal' upon receiving `start_finish' signal from server."
  ;; Make EPC process.
  (setq blink-search-epc-process (make-blink-search-epc-manager
                                  :server-process blink-search-internal-process
                                  :commands (cons blink-search-internal-process-prog blink-search-internal-process-args)
                                  :title (mapconcat 'identity (cons blink-search-internal-process-prog blink-search-internal-process-args) " ")
                                  :port blink-search-epc-port
                                  :connection (blink-search-epc-connect "localhost" blink-search-epc-port)
                                  ))
  (blink-search-epc-init-epc-layer blink-search-epc-process)
  (setq blink-search-is-starting nil)

  (blink-search-start-elisp-symbol-update)
  (blink-search-start-recent-file-update)
  (blink-search-buffer-list-update)
  )

(defvar blink-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-g") 'blink-search-quit)
    (define-key map (kbd "ESC ESC ESC") 'blink-search-quit)
    (define-key map (kbd "M-h") 'blink-search-quit)
    map)
  "Keymap used by `blink-search-mode'.")

(define-derived-mode blink-search-mode text-mode "blink-search"
  ;; Kill all local variables.
  (kill-all-local-variables)
  ;; Switch new mode.
  (setq major-mode 'blink-search-mode)
  (setq mode-name "snails")
  ;; Injection keymap.
  (use-local-map blink-search-mode-map))

(defvar blink-search-window-configuration nil)

(defun blink-search ()
  (interactive)
  (blink-search-init-layout))

(defun blink-search-quit ()
  (interactive)
  (when blink-search-window-configuration
    (set-window-configuration blink-search-window-configuration)
    (setq blink-search-window-configuration nil)))

(defvar blink-search-input-buffer " *blink search input*")
(defvar blink-search-candidate-buffer " *blink search candidate*")
(defvar blink-search-backend-buffer " *blink search backend*")

(defun blink-search-init-layout ()
  ;; Save window configuration.
  (unless blink-search-window-configuration
    (setq blink-search-window-configuration (current-window-configuration)))

  ;; Create buffers.
  (with-current-buffer (get-buffer-create blink-search-input-buffer)
    (erase-buffer)
    (blink-search-mode)
    (run-hooks 'blink-search-mode-hook)
    (add-hook 'after-change-functions 'blink-search-monitor-input nil t)

    (blink-search-disable-options nil))

  (with-current-buffer (get-buffer-create blink-search-candidate-buffer)
    (erase-buffer)
    (blink-search-disable-options t))

  (with-current-buffer (get-buffer-create blink-search-backend-buffer)
    (erase-buffer)
    (blink-search-disable-options t))

  ;; Clean layout.
  (delete-other-windows)

  ;; Show input buffer.
  (split-window)
  (other-window -1)
  (switch-to-buffer blink-search-input-buffer)

  ;; Show candidate buffer.
  (split-window (selected-window) (line-pixel-height) 'below t)
  (other-window 1)
  (switch-to-buffer blink-search-candidate-buffer)

  ;; Show backend buffer.
  (split-window (selected-window) nil 'right t)
  (other-window 1)
  (switch-to-buffer blink-search-backend-buffer)

  ;; Select input window.
  (select-window (get-buffer-window blink-search-input-buffer))

  ;; Pass search values to Python side.
  (blink-search-buffer-list-update)

  ;; Start process.
  (unless blink-search-is-starting
    (blink-search-start-process)))

(defun blink-search-get-window-allocation (&optional window)
  "Get WINDOW allocation."
  (let* ((window-edges (window-pixel-edges window))
         (x (nth 0 window-edges))
         (y (+ (nth 1 window-edges)
               (if (version< emacs-version "27.0")
                   (window-header-line-height window)
                 (window-tab-line-height window))))
         (w (- (nth 2 window-edges) x))
         (h (- (nth 3 window-edges) (window-mode-line-height window) y)))
    (list x y w h)))

(defun blink-search-disable-options (&optional disable-cursor)
  "Disable many options for blink-search buffers."
  ;; Disable line numbers mode.
  (when display-line-numbers
    (setq-local display-line-numbers nil))
  ;; Disable tab-line.
  (when (version< "27.0" emacs-version)
    (setq-local tab-line-format nil))
  ;; Disable hl-line, header-line and mode-line in input buffer.
  (setq-local header-line-format nil)
  (setq-local mode-line-format nil)
  ;; Disable cursor type if option `disable-cursor' is non-nil.
  (when disable-cursor
    (setq-local cursor-type nil)))

(defun blink-search-monitor-input (_begin _end _length)
  "This is input monitor callback to hook `after-change-functions'."
  ;; Send new input to all backends when user change input.
  (when (string-equal (buffer-name) blink-search-input-buffer)
    (let* ((input (with-current-buffer blink-search-input-buffer
                    (buffer-substring-no-properties (point-min) (point-max))))
           (row-number (/ (nth 3 (blink-search-get-window-allocation (get-buffer-window blink-search-candidate-buffer))) (line-pixel-height))))
      (blink-search-call-async "search" input row-number)
      )))

;; Elisp symbol.
(defcustom blink-search-elisp-symbol-update-idle 5
  "The idle seconds to update elisp symbols."
  :type 'float
  :group 'blink-search)

(defvar blink-search-elisp-symbol-timer nil)
(defvar blink-search-elisp-symbol-size 0)

(defun blink-search-elisp-symbol-update ()
  "We need synchronize elisp symbols to Python side when idle."
  (let* ((symbols (all-completions "" obarray))
         (symbols-size (length symbols)))
    ;; Only synchronize when new symbol created.
    (unless (equal blink-search-elisp-symbol-size symbols-size)
      (blink-search-call-async "search_elisp_symbol_update" symbols)
      (setq blink-search-elisp-symbol-size symbols-size))))

(defun blink-search-start-elisp-symbol-update ()
  (blink-search-elisp-symbol-update)

  (unless blink-search-elisp-symbol-timer
    (setq blink-search-elisp-symbol-timer (run-with-idle-timer blink-search-elisp-symbol-update-idle t #'blink-search-elisp-symbol-update))))

(defun blink-search-stop-elisp-symbol-update ()
  (when blink-search-elisp-symbol-timer
    (cancel-timer blink-search-elisp-symbol-timer)
    (setq blink-search-elisp-symbol-timer nil)
    (setq blink-search-elisp-symbol-size 0)))

;; Recent files.
(defcustom blink-search-recent-file-update-idle 4
  "The idle seconds to update recent files."
  :type 'float
  :group 'blink-search)

(defvar blink-search-recent-file-timer nil)
(defvar blink-search-recent-file-size 0)

(defun blink-search-recent-file-update ()
  "We need synchronize recent files to Python side when idle."
  (let* ((files-size (length recentf-list)))
    ;; Only synchronize when new symbol created.
    (unless (equal blink-search-recent-file-size files-size)
      (blink-search-call-async "search_recent_file_update" recentf-list)
      (setq blink-search-recent-file-size files-size))))

(defun blink-search-start-recent-file-update ()
  (blink-search-recent-file-update)

  (unless blink-search-recent-file-timer
    (setq blink-search-recent-file-timer (run-with-idle-timer blink-search-recent-file-update-idle t #'blink-search-recent-file-update))))

(defun blink-search-stop-recent-file-update ()
  (when blink-search-recent-file-timer
    (cancel-timer blink-search-recent-file-timer)
    (setq blink-search-recent-file-timer nil)
    (setq blink-search-recent-file-size 0)))

(defun blink-search-buffer-list-update ()
  (when (blink-search-epc-live-p blink-search-epc-process)
    (blink-search-call-async "search_buffer_list_update" (mapcar #'buffer-name (buffer-list)))))

(defun blink-search-update-items (candidate-items backend-items)
  (save-excursion
    (with-current-buffer blink-search-candidate-buffer
      (erase-buffer)

      (when candidate-items
        (dolist (item candidate-items)
          (insert (format "%s %s\n" (plist-get item :candidate) (plist-get item :backend))))))
    (with-current-buffer blink-search-backend-buffer
      (erase-buffer)

      (when backend-items
        (dolist (item backend-items)
          (insert (format "%s\n" item)))))
    ))

(provide 'blink-search)

;;; blink-search.el ends here