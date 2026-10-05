import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/todays_five_pin_helper.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../utils/display_utils.dart';

/// Lists [existing] under [parentId] too, for the "Add here" action on a
/// "Did you mean" match, and shows a snackbar whose Undo removes the link.
///
/// Example: inside "Groceries", typing "buy milk" matches the Inbox task
/// "Buy milk". Tapping "Add here" files it under Groceries and takes it out of
/// the Inbox. Undo puts it back in the Inbox with no parent.
///
/// [selfMessage] is shown when [existing] is the parent itself, and
/// [alreadyLinkedMessage] when it is already a child of the parent. Neither
/// case changes anything or offers Undo.
///
/// [parentIsPinned] says whether the parent was in Today's 5 before the link.
/// The link makes the parent a non-leaf, so Today's 5 drops it; Undo pins it
/// again.
///
/// [onChanged] runs after the link and after an undo, so the caller can reload
/// what it shows.
Future<void> linkExistingHere(
  BuildContext context, {
  required Task existing,
  required int parentId,
  required String selfMessage,
  required String alreadyLinkedMessage,
  bool parentIsPinned = false,
  Future<void> Function()? onChanged,
}) async {
  final provider = context.read<TaskProvider>();
  final taskId = existing.id!;
  if (taskId == parentId) {
    showInfoSnackBar(context, selfMessage);
    return;
  }
  // Codex P2: linking a task that is already a child reports success
  // (addRelationship is INSERT-OR-IGNORE), and its Undo would then delete the
  // edge that was there before. Stop here with no link and no Undo.
  final childIds = await provider.getChildIds(parentId);
  if (!context.mounted) return;
  if (childIds.contains(taskId)) {
    showInfoSnackBar(context, alreadyLinkedMessage);
    return;
  }

  // CR-fix I-55: both screens called addParentToTask, which left an Inbox
  // task's Inbox flag set, so it appeared under the parent and in the Inbox.
  // fileTask also clears the flag, and unfileTask sets it again on Undo.
  final wasInbox = existing.isInbox;
  final ok = wasInbox
      ? await provider.fileTask(taskId, parentId)
      : await provider.addParentToTask(taskId, parentId);
  if (!context.mounted) return;
  if (!ok) {
    showInfoSnackBar(context, "Couldn't add — it would create a loop");
    return;
  }
  await onChanged?.call();
  if (!context.mounted) return;

  showInfoSnackBar(
    context,
    'Added "${existing.name}" here',
    onUndo: () async {
      // CR-fix M-53: Undo removed the link but left the parent out of
      // Today's 5. The pin is written before the link is removed: removing it
      // notifies the Today tab, which then reloads, finds the parent in the
      // saved list and keeps it because it is a leaf again.
      if (parentIsPinned) await pinIntoTodaysFive(parentId);
      if (wasInbox) {
        await provider.unfileTask(taskId, parentId);
      } else {
        await provider.removeParentFromTask(taskId, parentId);
      }
      await onChanged?.call();
    },
  );
}
