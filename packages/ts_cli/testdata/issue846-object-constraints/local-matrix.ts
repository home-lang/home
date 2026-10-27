declare let boolSlot: { value?: boolean };
boolSlot.value = "bad";
boolSlot.value = 1;
boolSlot.value = null;

declare let numberSlot: { value?: number };
numberSlot.value = "bad";
numberSlot.value = true;
numberSlot.value = null;

declare let stringSlot: { value?: string };
stringSlot.value = 1;
stringSlot.value = true;
stringSlot.value = null;
