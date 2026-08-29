// @ts-check

/**
 * @typedef {object} Model0
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box0
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project0
 * @param {Model0} input
 * @returns {string}
 */

/**
 * @template {Model0} T
 * @param {T} value
 * @returns {T}
 */
function preserve0(value) {
  return value;
}

class Store0 {
  /**
   * @param {Box0<Model0>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project0} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model0} */
const model0 = {
  id: 0, name: "model-0", meta: { active: true, label: "meta-0" },
};
const preserved0 = preserve0(model0);
/** @type {Box0<Model0>} */
const box0 = { value: preserved0, label: "box-0" };
/** @type {Project0} */
const project0 = (input) => `${input.meta.label}:${input.name}`;
const store0 = new Store0(box0);
const rendered0 = store0.read(project0);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult0 = {
  id: preserved0.id,
  name: preserved0.name,
  active: preserved0.meta.active,
  rendered: rendered0,
};

/**
 * @typedef {object} Model1
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box1
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project1
 * @param {Model1} input
 * @returns {string}
 */

/**
 * @template {Model1} T
 * @param {T} value
 * @returns {T}
 */
function preserve1(value) {
  return value;
}

class Store1 {
  /**
   * @param {Box1<Model1>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project1} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model1} */
const model1 = {
  id: 1, name: "model-1", meta: { active: false, label: "meta-1" },
};
const preserved1 = preserve1(model1);
/** @type {Box1<Model1>} */
const box1 = { value: preserved1, label: "box-1" };
/** @type {Project1} */
const project1 = (input) => `${input.meta.label}:${input.name}`;
const store1 = new Store1(box1);
const rendered1 = store1.read(project1);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult1 = {
  id: preserved1.id,
  name: preserved1.name,
  active: preserved1.meta.active,
  rendered: rendered1,
};

/**
 * @typedef {object} Model2
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box2
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project2
 * @param {Model2} input
 * @returns {string}
 */

/**
 * @template {Model2} T
 * @param {T} value
 * @returns {T}
 */
function preserve2(value) {
  return value;
}

class Store2 {
  /**
   * @param {Box2<Model2>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project2} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model2} */
const model2 = {
  id: 2, name: "model-2", meta: { active: true, label: "meta-2" },
};
const preserved2 = preserve2(model2);
/** @type {Box2<Model2>} */
const box2 = { value: preserved2, label: "box-2" };
/** @type {Project2} */
const project2 = (input) => `${input.meta.label}:${input.name}`;
const store2 = new Store2(box2);
const rendered2 = store2.read(project2);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult2 = {
  id: preserved2.id,
  name: preserved2.name,
  active: preserved2.meta.active,
  rendered: rendered2,
};

/**
 * @typedef {object} Model3
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box3
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project3
 * @param {Model3} input
 * @returns {string}
 */

/**
 * @template {Model3} T
 * @param {T} value
 * @returns {T}
 */
function preserve3(value) {
  return value;
}

class Store3 {
  /**
   * @param {Box3<Model3>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project3} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model3} */
const model3 = {
  id: 3, name: "model-3", meta: { active: false, label: "meta-3" },
};
const preserved3 = preserve3(model3);
/** @type {Box3<Model3>} */
const box3 = { value: preserved3, label: "box-3" };
/** @type {Project3} */
const project3 = (input) => `${input.meta.label}:${input.name}`;
const store3 = new Store3(box3);
const rendered3 = store3.read(project3);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult3 = {
  id: preserved3.id,
  name: preserved3.name,
  active: preserved3.meta.active,
  rendered: rendered3,
};

/**
 * @typedef {object} Model4
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box4
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project4
 * @param {Model4} input
 * @returns {string}
 */

/**
 * @template {Model4} T
 * @param {T} value
 * @returns {T}
 */
function preserve4(value) {
  return value;
}

class Store4 {
  /**
   * @param {Box4<Model4>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project4} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model4} */
const model4 = {
  id: 4, name: "model-4", meta: { active: true, label: "meta-4" },
};
const preserved4 = preserve4(model4);
/** @type {Box4<Model4>} */
const box4 = { value: preserved4, label: "box-4" };
/** @type {Project4} */
const project4 = (input) => `${input.meta.label}:${input.name}`;
const store4 = new Store4(box4);
const rendered4 = store4.read(project4);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult4 = {
  id: preserved4.id,
  name: preserved4.name,
  active: preserved4.meta.active,
  rendered: rendered4,
};

/**
 * @typedef {object} Model5
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box5
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project5
 * @param {Model5} input
 * @returns {string}
 */

/**
 * @template {Model5} T
 * @param {T} value
 * @returns {T}
 */
function preserve5(value) {
  return value;
}

class Store5 {
  /**
   * @param {Box5<Model5>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project5} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model5} */
const model5 = {
  id: 5, name: "model-5", meta: { active: false, label: "meta-5" },
};
const preserved5 = preserve5(model5);
/** @type {Box5<Model5>} */
const box5 = { value: preserved5, label: "box-5" };
/** @type {Project5} */
const project5 = (input) => `${input.meta.label}:${input.name}`;
const store5 = new Store5(box5);
const rendered5 = store5.read(project5);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult5 = {
  id: preserved5.id,
  name: preserved5.name,
  active: preserved5.meta.active,
  rendered: rendered5,
};

/**
 * @typedef {object} Model6
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box6
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project6
 * @param {Model6} input
 * @returns {string}
 */

/**
 * @template {Model6} T
 * @param {T} value
 * @returns {T}
 */
function preserve6(value) {
  return value;
}

class Store6 {
  /**
   * @param {Box6<Model6>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project6} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model6} */
const model6 = {
  id: 6, name: "model-6", meta: { active: true, label: "meta-6" },
};
const preserved6 = preserve6(model6);
/** @type {Box6<Model6>} */
const box6 = { value: preserved6, label: "box-6" };
/** @type {Project6} */
const project6 = (input) => `${input.meta.label}:${input.name}`;
const store6 = new Store6(box6);
const rendered6 = store6.read(project6);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult6 = {
  id: preserved6.id,
  name: preserved6.name,
  active: preserved6.meta.active,
  rendered: rendered6,
};

/**
 * @typedef {object} Model7
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box7
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project7
 * @param {Model7} input
 * @returns {string}
 */

/**
 * @template {Model7} T
 * @param {T} value
 * @returns {T}
 */
function preserve7(value) {
  return value;
}

class Store7 {
  /**
   * @param {Box7<Model7>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project7} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model7} */
const model7 = {
  id: 7, name: "model-7", meta: { active: false, label: "meta-7" },
};
const preserved7 = preserve7(model7);
/** @type {Box7<Model7>} */
const box7 = { value: preserved7, label: "box-7" };
/** @type {Project7} */
const project7 = (input) => `${input.meta.label}:${input.name}`;
const store7 = new Store7(box7);
const rendered7 = store7.read(project7);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult7 = {
  id: preserved7.id,
  name: preserved7.name,
  active: preserved7.meta.active,
  rendered: rendered7,
};

/**
 * @typedef {object} Model8
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box8
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project8
 * @param {Model8} input
 * @returns {string}
 */

/**
 * @template {Model8} T
 * @param {T} value
 * @returns {T}
 */
function preserve8(value) {
  return value;
}

class Store8 {
  /**
   * @param {Box8<Model8>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project8} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model8} */
const model8 = {
  id: 8, name: "model-8", meta: { active: true, label: "meta-8" },
};
const preserved8 = preserve8(model8);
/** @type {Box8<Model8>} */
const box8 = { value: preserved8, label: "box-8" };
/** @type {Project8} */
const project8 = (input) => `${input.meta.label}:${input.name}`;
const store8 = new Store8(box8);
const rendered8 = store8.read(project8);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult8 = {
  id: preserved8.id,
  name: preserved8.name,
  active: preserved8.meta.active,
  rendered: rendered8,
};

/**
 * @typedef {object} Model9
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box9
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project9
 * @param {Model9} input
 * @returns {string}
 */

/**
 * @template {Model9} T
 * @param {T} value
 * @returns {T}
 */
function preserve9(value) {
  return value;
}

class Store9 {
  /**
   * @param {Box9<Model9>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project9} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model9} */
const model9 = {
  id: 9, name: "model-9", meta: { active: false, label: "meta-9" },
};
const preserved9 = preserve9(model9);
/** @type {Box9<Model9>} */
const box9 = { value: preserved9, label: "box-9" };
/** @type {Project9} */
const project9 = (input) => `${input.meta.label}:${input.name}`;
const store9 = new Store9(box9);
const rendered9 = store9.read(project9);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult9 = {
  id: preserved9.id,
  name: preserved9.name,
  active: preserved9.meta.active,
  rendered: rendered9,
};

/**
 * @typedef {object} Model10
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box10
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project10
 * @param {Model10} input
 * @returns {string}
 */

/**
 * @template {Model10} T
 * @param {T} value
 * @returns {T}
 */
function preserve10(value) {
  return value;
}

class Store10 {
  /**
   * @param {Box10<Model10>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project10} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model10} */
const model10 = {
  id: 10, name: "model-10", meta: { active: true, label: "meta-10" },
};
const preserved10 = preserve10(model10);
/** @type {Box10<Model10>} */
const box10 = { value: preserved10, label: "box-10" };
/** @type {Project10} */
const project10 = (input) => `${input.meta.label}:${input.name}`;
const store10 = new Store10(box10);
const rendered10 = store10.read(project10);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult10 = {
  id: preserved10.id,
  name: preserved10.name,
  active: preserved10.meta.active,
  rendered: rendered10,
};

/**
 * @typedef {object} Model11
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box11
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project11
 * @param {Model11} input
 * @returns {string}
 */

/**
 * @template {Model11} T
 * @param {T} value
 * @returns {T}
 */
function preserve11(value) {
  return value;
}

class Store11 {
  /**
   * @param {Box11<Model11>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project11} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model11} */
const model11 = {
  id: 11, name: "model-11", meta: { active: false, label: "meta-11" },
};
const preserved11 = preserve11(model11);
/** @type {Box11<Model11>} */
const box11 = { value: preserved11, label: "box-11" };
/** @type {Project11} */
const project11 = (input) => `${input.meta.label}:${input.name}`;
const store11 = new Store11(box11);
const rendered11 = store11.read(project11);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult11 = {
  id: preserved11.id,
  name: preserved11.name,
  active: preserved11.meta.active,
  rendered: rendered11,
};

/**
 * @typedef {object} Model12
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box12
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project12
 * @param {Model12} input
 * @returns {string}
 */

/**
 * @template {Model12} T
 * @param {T} value
 * @returns {T}
 */
function preserve12(value) {
  return value;
}

class Store12 {
  /**
   * @param {Box12<Model12>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project12} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model12} */
const model12 = {
  id: 12, name: "model-12", meta: { active: true, label: "meta-12" },
};
const preserved12 = preserve12(model12);
/** @type {Box12<Model12>} */
const box12 = { value: preserved12, label: "box-12" };
/** @type {Project12} */
const project12 = (input) => `${input.meta.label}:${input.name}`;
const store12 = new Store12(box12);
const rendered12 = store12.read(project12);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult12 = {
  id: preserved12.id,
  name: preserved12.name,
  active: preserved12.meta.active,
  rendered: rendered12,
};

/**
 * @typedef {object} Model13
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box13
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project13
 * @param {Model13} input
 * @returns {string}
 */

/**
 * @template {Model13} T
 * @param {T} value
 * @returns {T}
 */
function preserve13(value) {
  return value;
}

class Store13 {
  /**
   * @param {Box13<Model13>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project13} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model13} */
const model13 = {
  id: 13, name: "model-13", meta: { active: false, label: "meta-13" },
};
const preserved13 = preserve13(model13);
/** @type {Box13<Model13>} */
const box13 = { value: preserved13, label: "box-13" };
/** @type {Project13} */
const project13 = (input) => `${input.meta.label}:${input.name}`;
const store13 = new Store13(box13);
const rendered13 = store13.read(project13);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult13 = {
  id: preserved13.id,
  name: preserved13.name,
  active: preserved13.meta.active,
  rendered: rendered13,
};

/**
 * @typedef {object} Model14
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box14
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project14
 * @param {Model14} input
 * @returns {string}
 */

/**
 * @template {Model14} T
 * @param {T} value
 * @returns {T}
 */
function preserve14(value) {
  return value;
}

class Store14 {
  /**
   * @param {Box14<Model14>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project14} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model14} */
const model14 = {
  id: 14, name: "model-14", meta: { active: true, label: "meta-14" },
};
const preserved14 = preserve14(model14);
/** @type {Box14<Model14>} */
const box14 = { value: preserved14, label: "box-14" };
/** @type {Project14} */
const project14 = (input) => `${input.meta.label}:${input.name}`;
const store14 = new Store14(box14);
const rendered14 = store14.read(project14);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult14 = {
  id: preserved14.id,
  name: preserved14.name,
  active: preserved14.meta.active,
  rendered: rendered14,
};

/**
 * @typedef {object} Model15
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box15
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project15
 * @param {Model15} input
 * @returns {string}
 */

/**
 * @template {Model15} T
 * @param {T} value
 * @returns {T}
 */
function preserve15(value) {
  return value;
}

class Store15 {
  /**
   * @param {Box15<Model15>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project15} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model15} */
const model15 = {
  id: 15, name: "model-15", meta: { active: false, label: "meta-15" },
};
const preserved15 = preserve15(model15);
/** @type {Box15<Model15>} */
const box15 = { value: preserved15, label: "box-15" };
/** @type {Project15} */
const project15 = (input) => `${input.meta.label}:${input.name}`;
const store15 = new Store15(box15);
const rendered15 = store15.read(project15);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult15 = {
  id: preserved15.id,
  name: preserved15.name,
  active: preserved15.meta.active,
  rendered: rendered15,
};

/**
 * @typedef {object} Model16
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box16
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project16
 * @param {Model16} input
 * @returns {string}
 */

/**
 * @template {Model16} T
 * @param {T} value
 * @returns {T}
 */
function preserve16(value) {
  return value;
}

class Store16 {
  /**
   * @param {Box16<Model16>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project16} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model16} */
const model16 = {
  id: 16, name: "model-16", meta: { active: true, label: "meta-16" },
};
const preserved16 = preserve16(model16);
/** @type {Box16<Model16>} */
const box16 = { value: preserved16, label: "box-16" };
/** @type {Project16} */
const project16 = (input) => `${input.meta.label}:${input.name}`;
const store16 = new Store16(box16);
const rendered16 = store16.read(project16);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult16 = {
  id: preserved16.id,
  name: preserved16.name,
  active: preserved16.meta.active,
  rendered: rendered16,
};

/**
 * @typedef {object} Model17
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box17
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project17
 * @param {Model17} input
 * @returns {string}
 */

/**
 * @template {Model17} T
 * @param {T} value
 * @returns {T}
 */
function preserve17(value) {
  return value;
}

class Store17 {
  /**
   * @param {Box17<Model17>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project17} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model17} */
const model17 = {
  id: 17, name: "model-17", meta: { active: false, label: "meta-17" },
};
const preserved17 = preserve17(model17);
/** @type {Box17<Model17>} */
const box17 = { value: preserved17, label: "box-17" };
/** @type {Project17} */
const project17 = (input) => `${input.meta.label}:${input.name}`;
const store17 = new Store17(box17);
const rendered17 = store17.read(project17);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult17 = {
  id: preserved17.id,
  name: preserved17.name,
  active: preserved17.meta.active,
  rendered: rendered17,
};

/**
 * @typedef {object} Model18
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box18
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project18
 * @param {Model18} input
 * @returns {string}
 */

/**
 * @template {Model18} T
 * @param {T} value
 * @returns {T}
 */
function preserve18(value) {
  return value;
}

class Store18 {
  /**
   * @param {Box18<Model18>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project18} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model18} */
const model18 = {
  id: 18, name: "model-18", meta: { active: true, label: "meta-18" },
};
const preserved18 = preserve18(model18);
/** @type {Box18<Model18>} */
const box18 = { value: preserved18, label: "box-18" };
/** @type {Project18} */
const project18 = (input) => `${input.meta.label}:${input.name}`;
const store18 = new Store18(box18);
const rendered18 = store18.read(project18);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult18 = {
  id: preserved18.id,
  name: preserved18.name,
  active: preserved18.meta.active,
  rendered: rendered18,
};

/**
 * @typedef {object} Model19
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box19
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project19
 * @param {Model19} input
 * @returns {string}
 */

/**
 * @template {Model19} T
 * @param {T} value
 * @returns {T}
 */
function preserve19(value) {
  return value;
}

class Store19 {
  /**
   * @param {Box19<Model19>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project19} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model19} */
const model19 = {
  id: 19, name: "model-19", meta: { active: false, label: "meta-19" },
};
const preserved19 = preserve19(model19);
/** @type {Box19<Model19>} */
const box19 = { value: preserved19, label: "box-19" };
/** @type {Project19} */
const project19 = (input) => `${input.meta.label}:${input.name}`;
const store19 = new Store19(box19);
const rendered19 = store19.read(project19);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult19 = {
  id: preserved19.id,
  name: preserved19.name,
  active: preserved19.meta.active,
  rendered: rendered19,
};

/**
 * @typedef {object} Model20
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box20
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project20
 * @param {Model20} input
 * @returns {string}
 */

/**
 * @template {Model20} T
 * @param {T} value
 * @returns {T}
 */
function preserve20(value) {
  return value;
}

class Store20 {
  /**
   * @param {Box20<Model20>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project20} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model20} */
const model20 = {
  id: 20, name: "model-20", meta: { active: true, label: "meta-20" },
};
const preserved20 = preserve20(model20);
/** @type {Box20<Model20>} */
const box20 = { value: preserved20, label: "box-20" };
/** @type {Project20} */
const project20 = (input) => `${input.meta.label}:${input.name}`;
const store20 = new Store20(box20);
const rendered20 = store20.read(project20);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult20 = {
  id: preserved20.id,
  name: preserved20.name,
  active: preserved20.meta.active,
  rendered: rendered20,
};

/**
 * @typedef {object} Model21
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box21
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project21
 * @param {Model21} input
 * @returns {string}
 */

/**
 * @template {Model21} T
 * @param {T} value
 * @returns {T}
 */
function preserve21(value) {
  return value;
}

class Store21 {
  /**
   * @param {Box21<Model21>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project21} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model21} */
const model21 = {
  id: 21, name: "model-21", meta: { active: false, label: "meta-21" },
};
const preserved21 = preserve21(model21);
/** @type {Box21<Model21>} */
const box21 = { value: preserved21, label: "box-21" };
/** @type {Project21} */
const project21 = (input) => `${input.meta.label}:${input.name}`;
const store21 = new Store21(box21);
const rendered21 = store21.read(project21);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult21 = {
  id: preserved21.id,
  name: preserved21.name,
  active: preserved21.meta.active,
  rendered: rendered21,
};

/**
 * @typedef {object} Model22
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box22
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project22
 * @param {Model22} input
 * @returns {string}
 */

/**
 * @template {Model22} T
 * @param {T} value
 * @returns {T}
 */
function preserve22(value) {
  return value;
}

class Store22 {
  /**
   * @param {Box22<Model22>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project22} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model22} */
const model22 = {
  id: 22, name: "model-22", meta: { active: true, label: "meta-22" },
};
const preserved22 = preserve22(model22);
/** @type {Box22<Model22>} */
const box22 = { value: preserved22, label: "box-22" };
/** @type {Project22} */
const project22 = (input) => `${input.meta.label}:${input.name}`;
const store22 = new Store22(box22);
const rendered22 = store22.read(project22);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult22 = {
  id: preserved22.id,
  name: preserved22.name,
  active: preserved22.meta.active,
  rendered: rendered22,
};

/**
 * @typedef {object} Model23
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box23
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project23
 * @param {Model23} input
 * @returns {string}
 */

/**
 * @template {Model23} T
 * @param {T} value
 * @returns {T}
 */
function preserve23(value) {
  return value;
}

class Store23 {
  /**
   * @param {Box23<Model23>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project23} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model23} */
const model23 = {
  id: 23, name: "model-23", meta: { active: false, label: "meta-23" },
};
const preserved23 = preserve23(model23);
/** @type {Box23<Model23>} */
const box23 = { value: preserved23, label: "box-23" };
/** @type {Project23} */
const project23 = (input) => `${input.meta.label}:${input.name}`;
const store23 = new Store23(box23);
const rendered23 = store23.read(project23);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult23 = {
  id: preserved23.id,
  name: preserved23.name,
  active: preserved23.meta.active,
  rendered: rendered23,
};

/**
 * @typedef {object} Model24
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box24
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project24
 * @param {Model24} input
 * @returns {string}
 */

/**
 * @template {Model24} T
 * @param {T} value
 * @returns {T}
 */
function preserve24(value) {
  return value;
}

class Store24 {
  /**
   * @param {Box24<Model24>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project24} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model24} */
const model24 = {
  id: 24, name: "model-24", meta: { active: true, label: "meta-24" },
};
const preserved24 = preserve24(model24);
/** @type {Box24<Model24>} */
const box24 = { value: preserved24, label: "box-24" };
/** @type {Project24} */
const project24 = (input) => `${input.meta.label}:${input.name}`;
const store24 = new Store24(box24);
const rendered24 = store24.read(project24);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult24 = {
  id: preserved24.id,
  name: preserved24.name,
  active: preserved24.meta.active,
  rendered: rendered24,
};

/**
 * @typedef {object} Model25
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box25
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project25
 * @param {Model25} input
 * @returns {string}
 */

/**
 * @template {Model25} T
 * @param {T} value
 * @returns {T}
 */
function preserve25(value) {
  return value;
}

class Store25 {
  /**
   * @param {Box25<Model25>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project25} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model25} */
const model25 = {
  id: 25, name: "model-25", meta: { active: false, label: "meta-25" },
};
const preserved25 = preserve25(model25);
/** @type {Box25<Model25>} */
const box25 = { value: preserved25, label: "box-25" };
/** @type {Project25} */
const project25 = (input) => `${input.meta.label}:${input.name}`;
const store25 = new Store25(box25);
const rendered25 = store25.read(project25);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult25 = {
  id: preserved25.id,
  name: preserved25.name,
  active: preserved25.meta.active,
  rendered: rendered25,
};

/**
 * @typedef {object} Model26
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box26
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project26
 * @param {Model26} input
 * @returns {string}
 */

/**
 * @template {Model26} T
 * @param {T} value
 * @returns {T}
 */
function preserve26(value) {
  return value;
}

class Store26 {
  /**
   * @param {Box26<Model26>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project26} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model26} */
const model26 = {
  id: 26, name: "model-26", meta: { active: true, label: "meta-26" },
};
const preserved26 = preserve26(model26);
/** @type {Box26<Model26>} */
const box26 = { value: preserved26, label: "box-26" };
/** @type {Project26} */
const project26 = (input) => `${input.meta.label}:${input.name}`;
const store26 = new Store26(box26);
const rendered26 = store26.read(project26);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult26 = {
  id: preserved26.id,
  name: preserved26.name,
  active: preserved26.meta.active,
  rendered: rendered26,
};

/**
 * @typedef {object} Model27
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box27
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project27
 * @param {Model27} input
 * @returns {string}
 */

/**
 * @template {Model27} T
 * @param {T} value
 * @returns {T}
 */
function preserve27(value) {
  return value;
}

class Store27 {
  /**
   * @param {Box27<Model27>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project27} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model27} */
const model27 = {
  id: 27, name: "model-27", meta: { active: false, label: "meta-27" },
};
const preserved27 = preserve27(model27);
/** @type {Box27<Model27>} */
const box27 = { value: preserved27, label: "box-27" };
/** @type {Project27} */
const project27 = (input) => `${input.meta.label}:${input.name}`;
const store27 = new Store27(box27);
const rendered27 = store27.read(project27);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult27 = {
  id: preserved27.id,
  name: preserved27.name,
  active: preserved27.meta.active,
  rendered: rendered27,
};

/**
 * @typedef {object} Model28
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box28
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project28
 * @param {Model28} input
 * @returns {string}
 */

/**
 * @template {Model28} T
 * @param {T} value
 * @returns {T}
 */
function preserve28(value) {
  return value;
}

class Store28 {
  /**
   * @param {Box28<Model28>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project28} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model28} */
const model28 = {
  id: 28, name: "model-28", meta: { active: true, label: "meta-28" },
};
const preserved28 = preserve28(model28);
/** @type {Box28<Model28>} */
const box28 = { value: preserved28, label: "box-28" };
/** @type {Project28} */
const project28 = (input) => `${input.meta.label}:${input.name}`;
const store28 = new Store28(box28);
const rendered28 = store28.read(project28);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult28 = {
  id: preserved28.id,
  name: preserved28.name,
  active: preserved28.meta.active,
  rendered: rendered28,
};

/**
 * @typedef {object} Model29
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box29
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project29
 * @param {Model29} input
 * @returns {string}
 */

/**
 * @template {Model29} T
 * @param {T} value
 * @returns {T}
 */
function preserve29(value) {
  return value;
}

class Store29 {
  /**
   * @param {Box29<Model29>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project29} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model29} */
const model29 = {
  id: 29, name: "model-29", meta: { active: false, label: "meta-29" },
};
const preserved29 = preserve29(model29);
/** @type {Box29<Model29>} */
const box29 = { value: preserved29, label: "box-29" };
/** @type {Project29} */
const project29 = (input) => `${input.meta.label}:${input.name}`;
const store29 = new Store29(box29);
const rendered29 = store29.read(project29);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult29 = {
  id: preserved29.id,
  name: preserved29.name,
  active: preserved29.meta.active,
  rendered: rendered29,
};

/**
 * @typedef {object} Model30
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box30
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project30
 * @param {Model30} input
 * @returns {string}
 */

/**
 * @template {Model30} T
 * @param {T} value
 * @returns {T}
 */
function preserve30(value) {
  return value;
}

class Store30 {
  /**
   * @param {Box30<Model30>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project30} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model30} */
const model30 = {
  id: 30, name: "model-30", meta: { active: true, label: "meta-30" },
};
const preserved30 = preserve30(model30);
/** @type {Box30<Model30>} */
const box30 = { value: preserved30, label: "box-30" };
/** @type {Project30} */
const project30 = (input) => `${input.meta.label}:${input.name}`;
const store30 = new Store30(box30);
const rendered30 = store30.read(project30);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult30 = {
  id: preserved30.id,
  name: preserved30.name,
  active: preserved30.meta.active,
  rendered: rendered30,
};

/**
 * @typedef {object} Model31
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box31
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project31
 * @param {Model31} input
 * @returns {string}
 */

/**
 * @template {Model31} T
 * @param {T} value
 * @returns {T}
 */
function preserve31(value) {
  return value;
}

class Store31 {
  /**
   * @param {Box31<Model31>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project31} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model31} */
const model31 = {
  id: 31, name: "model-31", meta: { active: false, label: "meta-31" },
};
const preserved31 = preserve31(model31);
/** @type {Box31<Model31>} */
const box31 = { value: preserved31, label: "box-31" };
/** @type {Project31} */
const project31 = (input) => `${input.meta.label}:${input.name}`;
const store31 = new Store31(box31);
const rendered31 = store31.read(project31);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult31 = {
  id: preserved31.id,
  name: preserved31.name,
  active: preserved31.meta.active,
  rendered: rendered31,
};

/**
 * @typedef {object} Model32
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box32
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project32
 * @param {Model32} input
 * @returns {string}
 */

/**
 * @template {Model32} T
 * @param {T} value
 * @returns {T}
 */
function preserve32(value) {
  return value;
}

class Store32 {
  /**
   * @param {Box32<Model32>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project32} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model32} */
const model32 = {
  id: 32, name: "model-32", meta: { active: true, label: "meta-32" },
};
const preserved32 = preserve32(model32);
/** @type {Box32<Model32>} */
const box32 = { value: preserved32, label: "box-32" };
/** @type {Project32} */
const project32 = (input) => `${input.meta.label}:${input.name}`;
const store32 = new Store32(box32);
const rendered32 = store32.read(project32);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult32 = {
  id: preserved32.id,
  name: preserved32.name,
  active: preserved32.meta.active,
  rendered: rendered32,
};

/**
 * @typedef {object} Model33
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box33
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project33
 * @param {Model33} input
 * @returns {string}
 */

/**
 * @template {Model33} T
 * @param {T} value
 * @returns {T}
 */
function preserve33(value) {
  return value;
}

class Store33 {
  /**
   * @param {Box33<Model33>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project33} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model33} */
const model33 = {
  id: 33, name: "model-33", meta: { active: false, label: "meta-33" },
};
const preserved33 = preserve33(model33);
/** @type {Box33<Model33>} */
const box33 = { value: preserved33, label: "box-33" };
/** @type {Project33} */
const project33 = (input) => `${input.meta.label}:${input.name}`;
const store33 = new Store33(box33);
const rendered33 = store33.read(project33);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult33 = {
  id: preserved33.id,
  name: preserved33.name,
  active: preserved33.meta.active,
  rendered: rendered33,
};

/**
 * @typedef {object} Model34
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box34
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project34
 * @param {Model34} input
 * @returns {string}
 */

/**
 * @template {Model34} T
 * @param {T} value
 * @returns {T}
 */
function preserve34(value) {
  return value;
}

class Store34 {
  /**
   * @param {Box34<Model34>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project34} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model34} */
const model34 = {
  id: 34, name: "model-34", meta: { active: true, label: "meta-34" },
};
const preserved34 = preserve34(model34);
/** @type {Box34<Model34>} */
const box34 = { value: preserved34, label: "box-34" };
/** @type {Project34} */
const project34 = (input) => `${input.meta.label}:${input.name}`;
const store34 = new Store34(box34);
const rendered34 = store34.read(project34);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult34 = {
  id: preserved34.id,
  name: preserved34.name,
  active: preserved34.meta.active,
  rendered: rendered34,
};

/**
 * @typedef {object} Model35
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box35
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project35
 * @param {Model35} input
 * @returns {string}
 */

/**
 * @template {Model35} T
 * @param {T} value
 * @returns {T}
 */
function preserve35(value) {
  return value;
}

class Store35 {
  /**
   * @param {Box35<Model35>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project35} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model35} */
const model35 = {
  id: 35, name: "model-35", meta: { active: false, label: "meta-35" },
};
const preserved35 = preserve35(model35);
/** @type {Box35<Model35>} */
const box35 = { value: preserved35, label: "box-35" };
/** @type {Project35} */
const project35 = (input) => `${input.meta.label}:${input.name}`;
const store35 = new Store35(box35);
const rendered35 = store35.read(project35);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult35 = {
  id: preserved35.id,
  name: preserved35.name,
  active: preserved35.meta.active,
  rendered: rendered35,
};

/**
 * @typedef {object} Model36
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box36
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project36
 * @param {Model36} input
 * @returns {string}
 */

/**
 * @template {Model36} T
 * @param {T} value
 * @returns {T}
 */
function preserve36(value) {
  return value;
}

class Store36 {
  /**
   * @param {Box36<Model36>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project36} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model36} */
const model36 = {
  id: 36, name: "model-36", meta: { active: true, label: "meta-36" },
};
const preserved36 = preserve36(model36);
/** @type {Box36<Model36>} */
const box36 = { value: preserved36, label: "box-36" };
/** @type {Project36} */
const project36 = (input) => `${input.meta.label}:${input.name}`;
const store36 = new Store36(box36);
const rendered36 = store36.read(project36);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult36 = {
  id: preserved36.id,
  name: preserved36.name,
  active: preserved36.meta.active,
  rendered: rendered36,
};

/**
 * @typedef {object} Model37
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box37
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project37
 * @param {Model37} input
 * @returns {string}
 */

/**
 * @template {Model37} T
 * @param {T} value
 * @returns {T}
 */
function preserve37(value) {
  return value;
}

class Store37 {
  /**
   * @param {Box37<Model37>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project37} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model37} */
const model37 = {
  id: 37, name: "model-37", meta: { active: false, label: "meta-37" },
};
const preserved37 = preserve37(model37);
/** @type {Box37<Model37>} */
const box37 = { value: preserved37, label: "box-37" };
/** @type {Project37} */
const project37 = (input) => `${input.meta.label}:${input.name}`;
const store37 = new Store37(box37);
const rendered37 = store37.read(project37);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult37 = {
  id: preserved37.id,
  name: preserved37.name,
  active: preserved37.meta.active,
  rendered: rendered37,
};

/**
 * @typedef {object} Model38
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box38
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project38
 * @param {Model38} input
 * @returns {string}
 */

/**
 * @template {Model38} T
 * @param {T} value
 * @returns {T}
 */
function preserve38(value) {
  return value;
}

class Store38 {
  /**
   * @param {Box38<Model38>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project38} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model38} */
const model38 = {
  id: 38, name: "model-38", meta: { active: true, label: "meta-38" },
};
const preserved38 = preserve38(model38);
/** @type {Box38<Model38>} */
const box38 = { value: preserved38, label: "box-38" };
/** @type {Project38} */
const project38 = (input) => `${input.meta.label}:${input.name}`;
const store38 = new Store38(box38);
const rendered38 = store38.read(project38);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult38 = {
  id: preserved38.id,
  name: preserved38.name,
  active: preserved38.meta.active,
  rendered: rendered38,
};

/**
 * @typedef {object} Model39
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box39
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project39
 * @param {Model39} input
 * @returns {string}
 */

/**
 * @template {Model39} T
 * @param {T} value
 * @returns {T}
 */
function preserve39(value) {
  return value;
}

class Store39 {
  /**
   * @param {Box39<Model39>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project39} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model39} */
const model39 = {
  id: 39, name: "model-39", meta: { active: false, label: "meta-39" },
};
const preserved39 = preserve39(model39);
/** @type {Box39<Model39>} */
const box39 = { value: preserved39, label: "box-39" };
/** @type {Project39} */
const project39 = (input) => `${input.meta.label}:${input.name}`;
const store39 = new Store39(box39);
const rendered39 = store39.read(project39);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult39 = {
  id: preserved39.id,
  name: preserved39.name,
  active: preserved39.meta.active,
  rendered: rendered39,
};

/**
 * @typedef {object} Model40
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box40
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project40
 * @param {Model40} input
 * @returns {string}
 */

/**
 * @template {Model40} T
 * @param {T} value
 * @returns {T}
 */
function preserve40(value) {
  return value;
}

class Store40 {
  /**
   * @param {Box40<Model40>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project40} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model40} */
const model40 = {
  id: 40, name: "model-40", meta: { active: true, label: "meta-40" },
};
const preserved40 = preserve40(model40);
/** @type {Box40<Model40>} */
const box40 = { value: preserved40, label: "box-40" };
/** @type {Project40} */
const project40 = (input) => `${input.meta.label}:${input.name}`;
const store40 = new Store40(box40);
const rendered40 = store40.read(project40);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult40 = {
  id: preserved40.id,
  name: preserved40.name,
  active: preserved40.meta.active,
  rendered: rendered40,
};

/**
 * @typedef {object} Model41
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box41
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project41
 * @param {Model41} input
 * @returns {string}
 */

/**
 * @template {Model41} T
 * @param {T} value
 * @returns {T}
 */
function preserve41(value) {
  return value;
}

class Store41 {
  /**
   * @param {Box41<Model41>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project41} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model41} */
const model41 = {
  id: 41, name: "model-41", meta: { active: false, label: "meta-41" },
};
const preserved41 = preserve41(model41);
/** @type {Box41<Model41>} */
const box41 = { value: preserved41, label: "box-41" };
/** @type {Project41} */
const project41 = (input) => `${input.meta.label}:${input.name}`;
const store41 = new Store41(box41);
const rendered41 = store41.read(project41);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult41 = {
  id: preserved41.id,
  name: preserved41.name,
  active: preserved41.meta.active,
  rendered: rendered41,
};

/**
 * @typedef {object} Model42
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box42
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project42
 * @param {Model42} input
 * @returns {string}
 */

/**
 * @template {Model42} T
 * @param {T} value
 * @returns {T}
 */
function preserve42(value) {
  return value;
}

class Store42 {
  /**
   * @param {Box42<Model42>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project42} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model42} */
const model42 = {
  id: 42, name: "model-42", meta: { active: true, label: "meta-42" },
};
const preserved42 = preserve42(model42);
/** @type {Box42<Model42>} */
const box42 = { value: preserved42, label: "box-42" };
/** @type {Project42} */
const project42 = (input) => `${input.meta.label}:${input.name}`;
const store42 = new Store42(box42);
const rendered42 = store42.read(project42);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult42 = {
  id: preserved42.id,
  name: preserved42.name,
  active: preserved42.meta.active,
  rendered: rendered42,
};

/**
 * @typedef {object} Model43
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box43
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project43
 * @param {Model43} input
 * @returns {string}
 */

/**
 * @template {Model43} T
 * @param {T} value
 * @returns {T}
 */
function preserve43(value) {
  return value;
}

class Store43 {
  /**
   * @param {Box43<Model43>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project43} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model43} */
const model43 = {
  id: 43, name: "model-43", meta: { active: false, label: "meta-43" },
};
const preserved43 = preserve43(model43);
/** @type {Box43<Model43>} */
const box43 = { value: preserved43, label: "box-43" };
/** @type {Project43} */
const project43 = (input) => `${input.meta.label}:${input.name}`;
const store43 = new Store43(box43);
const rendered43 = store43.read(project43);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult43 = {
  id: preserved43.id,
  name: preserved43.name,
  active: preserved43.meta.active,
  rendered: rendered43,
};

/**
 * @typedef {object} Model44
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box44
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project44
 * @param {Model44} input
 * @returns {string}
 */

/**
 * @template {Model44} T
 * @param {T} value
 * @returns {T}
 */
function preserve44(value) {
  return value;
}

class Store44 {
  /**
   * @param {Box44<Model44>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project44} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model44} */
const model44 = {
  id: 44, name: "model-44", meta: { active: true, label: "meta-44" },
};
const preserved44 = preserve44(model44);
/** @type {Box44<Model44>} */
const box44 = { value: preserved44, label: "box-44" };
/** @type {Project44} */
const project44 = (input) => `${input.meta.label}:${input.name}`;
const store44 = new Store44(box44);
const rendered44 = store44.read(project44);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult44 = {
  id: preserved44.id,
  name: preserved44.name,
  active: preserved44.meta.active,
  rendered: rendered44,
};

/**
 * @typedef {object} Model45
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box45
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project45
 * @param {Model45} input
 * @returns {string}
 */

/**
 * @template {Model45} T
 * @param {T} value
 * @returns {T}
 */
function preserve45(value) {
  return value;
}

class Store45 {
  /**
   * @param {Box45<Model45>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project45} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model45} */
const model45 = {
  id: 45, name: "model-45", meta: { active: false, label: "meta-45" },
};
const preserved45 = preserve45(model45);
/** @type {Box45<Model45>} */
const box45 = { value: preserved45, label: "box-45" };
/** @type {Project45} */
const project45 = (input) => `${input.meta.label}:${input.name}`;
const store45 = new Store45(box45);
const rendered45 = store45.read(project45);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult45 = {
  id: preserved45.id,
  name: preserved45.name,
  active: preserved45.meta.active,
  rendered: rendered45,
};

/**
 * @typedef {object} Model46
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box46
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project46
 * @param {Model46} input
 * @returns {string}
 */

/**
 * @template {Model46} T
 * @param {T} value
 * @returns {T}
 */
function preserve46(value) {
  return value;
}

class Store46 {
  /**
   * @param {Box46<Model46>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project46} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model46} */
const model46 = {
  id: 46, name: "model-46", meta: { active: true, label: "meta-46" },
};
const preserved46 = preserve46(model46);
/** @type {Box46<Model46>} */
const box46 = { value: preserved46, label: "box-46" };
/** @type {Project46} */
const project46 = (input) => `${input.meta.label}:${input.name}`;
const store46 = new Store46(box46);
const rendered46 = store46.read(project46);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult46 = {
  id: preserved46.id,
  name: preserved46.name,
  active: preserved46.meta.active,
  rendered: rendered46,
};

/**
 * @typedef {object} Model47
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box47
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project47
 * @param {Model47} input
 * @returns {string}
 */

/**
 * @template {Model47} T
 * @param {T} value
 * @returns {T}
 */
function preserve47(value) {
  return value;
}

class Store47 {
  /**
   * @param {Box47<Model47>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project47} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model47} */
const model47 = {
  id: 47, name: "model-47", meta: { active: false, label: "meta-47" },
};
const preserved47 = preserve47(model47);
/** @type {Box47<Model47>} */
const box47 = { value: preserved47, label: "box-47" };
/** @type {Project47} */
const project47 = (input) => `${input.meta.label}:${input.name}`;
const store47 = new Store47(box47);
const rendered47 = store47.read(project47);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult47 = {
  id: preserved47.id,
  name: preserved47.name,
  active: preserved47.meta.active,
  rendered: rendered47,
};

/**
 * @typedef {object} Model48
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box48
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project48
 * @param {Model48} input
 * @returns {string}
 */

/**
 * @template {Model48} T
 * @param {T} value
 * @returns {T}
 */
function preserve48(value) {
  return value;
}

class Store48 {
  /**
   * @param {Box48<Model48>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project48} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model48} */
const model48 = {
  id: 48, name: "model-48", meta: { active: true, label: "meta-48" },
};
const preserved48 = preserve48(model48);
/** @type {Box48<Model48>} */
const box48 = { value: preserved48, label: "box-48" };
/** @type {Project48} */
const project48 = (input) => `${input.meta.label}:${input.name}`;
const store48 = new Store48(box48);
const rendered48 = store48.read(project48);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult48 = {
  id: preserved48.id,
  name: preserved48.name,
  active: preserved48.meta.active,
  rendered: rendered48,
};

/**
 * @typedef {object} Model49
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box49
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project49
 * @param {Model49} input
 * @returns {string}
 */

/**
 * @template {Model49} T
 * @param {T} value
 * @returns {T}
 */
function preserve49(value) {
  return value;
}

class Store49 {
  /**
   * @param {Box49<Model49>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project49} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model49} */
const model49 = {
  id: 49, name: "model-49", meta: { active: false, label: "meta-49" },
};
const preserved49 = preserve49(model49);
/** @type {Box49<Model49>} */
const box49 = { value: preserved49, label: "box-49" };
/** @type {Project49} */
const project49 = (input) => `${input.meta.label}:${input.name}`;
const store49 = new Store49(box49);
const rendered49 = store49.read(project49);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult49 = {
  id: preserved49.id,
  name: preserved49.name,
  active: preserved49.meta.active,
  rendered: rendered49,
};

/**
 * @typedef {object} Model50
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box50
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project50
 * @param {Model50} input
 * @returns {string}
 */

/**
 * @template {Model50} T
 * @param {T} value
 * @returns {T}
 */
function preserve50(value) {
  return value;
}

class Store50 {
  /**
   * @param {Box50<Model50>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project50} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model50} */
const model50 = {
  id: 50, name: "model-50", meta: { active: true, label: "meta-50" },
};
const preserved50 = preserve50(model50);
/** @type {Box50<Model50>} */
const box50 = { value: preserved50, label: "box-50" };
/** @type {Project50} */
const project50 = (input) => `${input.meta.label}:${input.name}`;
const store50 = new Store50(box50);
const rendered50 = store50.read(project50);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult50 = {
  id: preserved50.id,
  name: preserved50.name,
  active: preserved50.meta.active,
  rendered: rendered50,
};

/**
 * @typedef {object} Model51
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box51
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project51
 * @param {Model51} input
 * @returns {string}
 */

/**
 * @template {Model51} T
 * @param {T} value
 * @returns {T}
 */
function preserve51(value) {
  return value;
}

class Store51 {
  /**
   * @param {Box51<Model51>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project51} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model51} */
const model51 = {
  id: 51, name: "model-51", meta: { active: false, label: "meta-51" },
};
const preserved51 = preserve51(model51);
/** @type {Box51<Model51>} */
const box51 = { value: preserved51, label: "box-51" };
/** @type {Project51} */
const project51 = (input) => `${input.meta.label}:${input.name}`;
const store51 = new Store51(box51);
const rendered51 = store51.read(project51);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult51 = {
  id: preserved51.id,
  name: preserved51.name,
  active: preserved51.meta.active,
  rendered: rendered51,
};

/**
 * @typedef {object} Model52
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box52
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project52
 * @param {Model52} input
 * @returns {string}
 */

/**
 * @template {Model52} T
 * @param {T} value
 * @returns {T}
 */
function preserve52(value) {
  return value;
}

class Store52 {
  /**
   * @param {Box52<Model52>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project52} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model52} */
const model52 = {
  id: 52, name: "model-52", meta: { active: true, label: "meta-52" },
};
const preserved52 = preserve52(model52);
/** @type {Box52<Model52>} */
const box52 = { value: preserved52, label: "box-52" };
/** @type {Project52} */
const project52 = (input) => `${input.meta.label}:${input.name}`;
const store52 = new Store52(box52);
const rendered52 = store52.read(project52);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult52 = {
  id: preserved52.id,
  name: preserved52.name,
  active: preserved52.meta.active,
  rendered: rendered52,
};

/**
 * @typedef {object} Model53
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box53
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project53
 * @param {Model53} input
 * @returns {string}
 */

/**
 * @template {Model53} T
 * @param {T} value
 * @returns {T}
 */
function preserve53(value) {
  return value;
}

class Store53 {
  /**
   * @param {Box53<Model53>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project53} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model53} */
const model53 = {
  id: 53, name: "model-53", meta: { active: false, label: "meta-53" },
};
const preserved53 = preserve53(model53);
/** @type {Box53<Model53>} */
const box53 = { value: preserved53, label: "box-53" };
/** @type {Project53} */
const project53 = (input) => `${input.meta.label}:${input.name}`;
const store53 = new Store53(box53);
const rendered53 = store53.read(project53);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult53 = {
  id: preserved53.id,
  name: preserved53.name,
  active: preserved53.meta.active,
  rendered: rendered53,
};

/**
 * @typedef {object} Model54
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box54
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project54
 * @param {Model54} input
 * @returns {string}
 */

/**
 * @template {Model54} T
 * @param {T} value
 * @returns {T}
 */
function preserve54(value) {
  return value;
}

class Store54 {
  /**
   * @param {Box54<Model54>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project54} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model54} */
const model54 = {
  id: 54, name: "model-54", meta: { active: true, label: "meta-54" },
};
const preserved54 = preserve54(model54);
/** @type {Box54<Model54>} */
const box54 = { value: preserved54, label: "box-54" };
/** @type {Project54} */
const project54 = (input) => `${input.meta.label}:${input.name}`;
const store54 = new Store54(box54);
const rendered54 = store54.read(project54);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult54 = {
  id: preserved54.id,
  name: preserved54.name,
  active: preserved54.meta.active,
  rendered: rendered54,
};

/**
 * @typedef {object} Model55
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box55
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project55
 * @param {Model55} input
 * @returns {string}
 */

/**
 * @template {Model55} T
 * @param {T} value
 * @returns {T}
 */
function preserve55(value) {
  return value;
}

class Store55 {
  /**
   * @param {Box55<Model55>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project55} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model55} */
const model55 = {
  id: 55, name: "model-55", meta: { active: false, label: "meta-55" },
};
const preserved55 = preserve55(model55);
/** @type {Box55<Model55>} */
const box55 = { value: preserved55, label: "box-55" };
/** @type {Project55} */
const project55 = (input) => `${input.meta.label}:${input.name}`;
const store55 = new Store55(box55);
const rendered55 = store55.read(project55);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult55 = {
  id: preserved55.id,
  name: preserved55.name,
  active: preserved55.meta.active,
  rendered: rendered55,
};

/**
 * @typedef {object} Model56
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box56
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project56
 * @param {Model56} input
 * @returns {string}
 */

/**
 * @template {Model56} T
 * @param {T} value
 * @returns {T}
 */
function preserve56(value) {
  return value;
}

class Store56 {
  /**
   * @param {Box56<Model56>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project56} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model56} */
const model56 = {
  id: 56, name: "model-56", meta: { active: true, label: "meta-56" },
};
const preserved56 = preserve56(model56);
/** @type {Box56<Model56>} */
const box56 = { value: preserved56, label: "box-56" };
/** @type {Project56} */
const project56 = (input) => `${input.meta.label}:${input.name}`;
const store56 = new Store56(box56);
const rendered56 = store56.read(project56);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult56 = {
  id: preserved56.id,
  name: preserved56.name,
  active: preserved56.meta.active,
  rendered: rendered56,
};

/**
 * @typedef {object} Model57
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box57
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project57
 * @param {Model57} input
 * @returns {string}
 */

/**
 * @template {Model57} T
 * @param {T} value
 * @returns {T}
 */
function preserve57(value) {
  return value;
}

class Store57 {
  /**
   * @param {Box57<Model57>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project57} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model57} */
const model57 = {
  id: 57, name: "model-57", meta: { active: false, label: "meta-57" },
};
const preserved57 = preserve57(model57);
/** @type {Box57<Model57>} */
const box57 = { value: preserved57, label: "box-57" };
/** @type {Project57} */
const project57 = (input) => `${input.meta.label}:${input.name}`;
const store57 = new Store57(box57);
const rendered57 = store57.read(project57);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult57 = {
  id: preserved57.id,
  name: preserved57.name,
  active: preserved57.meta.active,
  rendered: rendered57,
};

/**
 * @typedef {object} Model58
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box58
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project58
 * @param {Model58} input
 * @returns {string}
 */

/**
 * @template {Model58} T
 * @param {T} value
 * @returns {T}
 */
function preserve58(value) {
  return value;
}

class Store58 {
  /**
   * @param {Box58<Model58>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project58} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model58} */
const model58 = {
  id: 58, name: "model-58", meta: { active: true, label: "meta-58" },
};
const preserved58 = preserve58(model58);
/** @type {Box58<Model58>} */
const box58 = { value: preserved58, label: "box-58" };
/** @type {Project58} */
const project58 = (input) => `${input.meta.label}:${input.name}`;
const store58 = new Store58(box58);
const rendered58 = store58.read(project58);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult58 = {
  id: preserved58.id,
  name: preserved58.name,
  active: preserved58.meta.active,
  rendered: rendered58,
};

/**
 * @typedef {object} Model59
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box59
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project59
 * @param {Model59} input
 * @returns {string}
 */

/**
 * @template {Model59} T
 * @param {T} value
 * @returns {T}
 */
function preserve59(value) {
  return value;
}

class Store59 {
  /**
   * @param {Box59<Model59>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project59} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model59} */
const model59 = {
  id: 59, name: "model-59", meta: { active: false, label: "meta-59" },
};
const preserved59 = preserve59(model59);
/** @type {Box59<Model59>} */
const box59 = { value: preserved59, label: "box-59" };
/** @type {Project59} */
const project59 = (input) => `${input.meta.label}:${input.name}`;
const store59 = new Store59(box59);
const rendered59 = store59.read(project59);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult59 = {
  id: preserved59.id,
  name: preserved59.name,
  active: preserved59.meta.active,
  rendered: rendered59,
};

/**
 * @typedef {object} Model60
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box60
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project60
 * @param {Model60} input
 * @returns {string}
 */

/**
 * @template {Model60} T
 * @param {T} value
 * @returns {T}
 */
function preserve60(value) {
  return value;
}

class Store60 {
  /**
   * @param {Box60<Model60>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project60} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model60} */
const model60 = {
  id: 60, name: "model-60", meta: { active: true, label: "meta-60" },
};
const preserved60 = preserve60(model60);
/** @type {Box60<Model60>} */
const box60 = { value: preserved60, label: "box-60" };
/** @type {Project60} */
const project60 = (input) => `${input.meta.label}:${input.name}`;
const store60 = new Store60(box60);
const rendered60 = store60.read(project60);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult60 = {
  id: preserved60.id,
  name: preserved60.name,
  active: preserved60.meta.active,
  rendered: rendered60,
};

/**
 * @typedef {object} Model61
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box61
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project61
 * @param {Model61} input
 * @returns {string}
 */

/**
 * @template {Model61} T
 * @param {T} value
 * @returns {T}
 */
function preserve61(value) {
  return value;
}

class Store61 {
  /**
   * @param {Box61<Model61>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project61} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model61} */
const model61 = {
  id: 61, name: "model-61", meta: { active: false, label: "meta-61" },
};
const preserved61 = preserve61(model61);
/** @type {Box61<Model61>} */
const box61 = { value: preserved61, label: "box-61" };
/** @type {Project61} */
const project61 = (input) => `${input.meta.label}:${input.name}`;
const store61 = new Store61(box61);
const rendered61 = store61.read(project61);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult61 = {
  id: preserved61.id,
  name: preserved61.name,
  active: preserved61.meta.active,
  rendered: rendered61,
};

/**
 * @typedef {object} Model62
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box62
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project62
 * @param {Model62} input
 * @returns {string}
 */

/**
 * @template {Model62} T
 * @param {T} value
 * @returns {T}
 */
function preserve62(value) {
  return value;
}

class Store62 {
  /**
   * @param {Box62<Model62>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project62} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model62} */
const model62 = {
  id: 62, name: "model-62", meta: { active: true, label: "meta-62" },
};
const preserved62 = preserve62(model62);
/** @type {Box62<Model62>} */
const box62 = { value: preserved62, label: "box-62" };
/** @type {Project62} */
const project62 = (input) => `${input.meta.label}:${input.name}`;
const store62 = new Store62(box62);
const rendered62 = store62.read(project62);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult62 = {
  id: preserved62.id,
  name: preserved62.name,
  active: preserved62.meta.active,
  rendered: rendered62,
};

/**
 * @typedef {object} Model63
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box63
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project63
 * @param {Model63} input
 * @returns {string}
 */

/**
 * @template {Model63} T
 * @param {T} value
 * @returns {T}
 */
function preserve63(value) {
  return value;
}

class Store63 {
  /**
   * @param {Box63<Model63>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project63} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model63} */
const model63 = {
  id: 63, name: "model-63", meta: { active: false, label: "meta-63" },
};
const preserved63 = preserve63(model63);
/** @type {Box63<Model63>} */
const box63 = { value: preserved63, label: "box-63" };
/** @type {Project63} */
const project63 = (input) => `${input.meta.label}:${input.name}`;
const store63 = new Store63(box63);
const rendered63 = store63.read(project63);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult63 = {
  id: preserved63.id,
  name: preserved63.name,
  active: preserved63.meta.active,
  rendered: rendered63,
};

/**
 * @typedef {object} Model64
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box64
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project64
 * @param {Model64} input
 * @returns {string}
 */

/**
 * @template {Model64} T
 * @param {T} value
 * @returns {T}
 */
function preserve64(value) {
  return value;
}

class Store64 {
  /**
   * @param {Box64<Model64>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project64} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model64} */
const model64 = {
  id: 64, name: "model-64", meta: { active: true, label: "meta-64" },
};
const preserved64 = preserve64(model64);
/** @type {Box64<Model64>} */
const box64 = { value: preserved64, label: "box-64" };
/** @type {Project64} */
const project64 = (input) => `${input.meta.label}:${input.name}`;
const store64 = new Store64(box64);
const rendered64 = store64.read(project64);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult64 = {
  id: preserved64.id,
  name: preserved64.name,
  active: preserved64.meta.active,
  rendered: rendered64,
};

/**
 * @typedef {object} Model65
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box65
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project65
 * @param {Model65} input
 * @returns {string}
 */

/**
 * @template {Model65} T
 * @param {T} value
 * @returns {T}
 */
function preserve65(value) {
  return value;
}

class Store65 {
  /**
   * @param {Box65<Model65>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project65} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model65} */
const model65 = {
  id: 65, name: "model-65", meta: { active: false, label: "meta-65" },
};
const preserved65 = preserve65(model65);
/** @type {Box65<Model65>} */
const box65 = { value: preserved65, label: "box-65" };
/** @type {Project65} */
const project65 = (input) => `${input.meta.label}:${input.name}`;
const store65 = new Store65(box65);
const rendered65 = store65.read(project65);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult65 = {
  id: preserved65.id,
  name: preserved65.name,
  active: preserved65.meta.active,
  rendered: rendered65,
};

/**
 * @typedef {object} Model66
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box66
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project66
 * @param {Model66} input
 * @returns {string}
 */

/**
 * @template {Model66} T
 * @param {T} value
 * @returns {T}
 */
function preserve66(value) {
  return value;
}

class Store66 {
  /**
   * @param {Box66<Model66>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project66} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model66} */
const model66 = {
  id: 66, name: "model-66", meta: { active: true, label: "meta-66" },
};
const preserved66 = preserve66(model66);
/** @type {Box66<Model66>} */
const box66 = { value: preserved66, label: "box-66" };
/** @type {Project66} */
const project66 = (input) => `${input.meta.label}:${input.name}`;
const store66 = new Store66(box66);
const rendered66 = store66.read(project66);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult66 = {
  id: preserved66.id,
  name: preserved66.name,
  active: preserved66.meta.active,
  rendered: rendered66,
};

/**
 * @typedef {object} Model67
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box67
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project67
 * @param {Model67} input
 * @returns {string}
 */

/**
 * @template {Model67} T
 * @param {T} value
 * @returns {T}
 */
function preserve67(value) {
  return value;
}

class Store67 {
  /**
   * @param {Box67<Model67>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project67} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model67} */
const model67 = {
  id: 67, name: "model-67", meta: { active: false, label: "meta-67" },
};
const preserved67 = preserve67(model67);
/** @type {Box67<Model67>} */
const box67 = { value: preserved67, label: "box-67" };
/** @type {Project67} */
const project67 = (input) => `${input.meta.label}:${input.name}`;
const store67 = new Store67(box67);
const rendered67 = store67.read(project67);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult67 = {
  id: preserved67.id,
  name: preserved67.name,
  active: preserved67.meta.active,
  rendered: rendered67,
};

/**
 * @typedef {object} Model68
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box68
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project68
 * @param {Model68} input
 * @returns {string}
 */

/**
 * @template {Model68} T
 * @param {T} value
 * @returns {T}
 */
function preserve68(value) {
  return value;
}

class Store68 {
  /**
   * @param {Box68<Model68>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project68} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model68} */
const model68 = {
  id: 68, name: "model-68", meta: { active: true, label: "meta-68" },
};
const preserved68 = preserve68(model68);
/** @type {Box68<Model68>} */
const box68 = { value: preserved68, label: "box-68" };
/** @type {Project68} */
const project68 = (input) => `${input.meta.label}:${input.name}`;
const store68 = new Store68(box68);
const rendered68 = store68.read(project68);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult68 = {
  id: preserved68.id,
  name: preserved68.name,
  active: preserved68.meta.active,
  rendered: rendered68,
};

/**
 * @typedef {object} Model69
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box69
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project69
 * @param {Model69} input
 * @returns {string}
 */

/**
 * @template {Model69} T
 * @param {T} value
 * @returns {T}
 */
function preserve69(value) {
  return value;
}

class Store69 {
  /**
   * @param {Box69<Model69>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project69} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model69} */
const model69 = {
  id: 69, name: "model-69", meta: { active: false, label: "meta-69" },
};
const preserved69 = preserve69(model69);
/** @type {Box69<Model69>} */
const box69 = { value: preserved69, label: "box-69" };
/** @type {Project69} */
const project69 = (input) => `${input.meta.label}:${input.name}`;
const store69 = new Store69(box69);
const rendered69 = store69.read(project69);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult69 = {
  id: preserved69.id,
  name: preserved69.name,
  active: preserved69.meta.active,
  rendered: rendered69,
};

/**
 * @typedef {object} Model70
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box70
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project70
 * @param {Model70} input
 * @returns {string}
 */

/**
 * @template {Model70} T
 * @param {T} value
 * @returns {T}
 */
function preserve70(value) {
  return value;
}

class Store70 {
  /**
   * @param {Box70<Model70>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project70} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model70} */
const model70 = {
  id: 70, name: "model-70", meta: { active: true, label: "meta-70" },
};
const preserved70 = preserve70(model70);
/** @type {Box70<Model70>} */
const box70 = { value: preserved70, label: "box-70" };
/** @type {Project70} */
const project70 = (input) => `${input.meta.label}:${input.name}`;
const store70 = new Store70(box70);
const rendered70 = store70.read(project70);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult70 = {
  id: preserved70.id,
  name: preserved70.name,
  active: preserved70.meta.active,
  rendered: rendered70,
};

/**
 * @typedef {object} Model71
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box71
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project71
 * @param {Model71} input
 * @returns {string}
 */

/**
 * @template {Model71} T
 * @param {T} value
 * @returns {T}
 */
function preserve71(value) {
  return value;
}

class Store71 {
  /**
   * @param {Box71<Model71>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project71} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model71} */
const model71 = {
  id: 71, name: "model-71", meta: { active: false, label: "meta-71" },
};
const preserved71 = preserve71(model71);
/** @type {Box71<Model71>} */
const box71 = { value: preserved71, label: "box-71" };
/** @type {Project71} */
const project71 = (input) => `${input.meta.label}:${input.name}`;
const store71 = new Store71(box71);
const rendered71 = store71.read(project71);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult71 = {
  id: preserved71.id,
  name: preserved71.name,
  active: preserved71.meta.active,
  rendered: rendered71,
};

/**
 * @typedef {object} Model72
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box72
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project72
 * @param {Model72} input
 * @returns {string}
 */

/**
 * @template {Model72} T
 * @param {T} value
 * @returns {T}
 */
function preserve72(value) {
  return value;
}

class Store72 {
  /**
   * @param {Box72<Model72>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project72} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model72} */
const model72 = {
  id: 72, name: "model-72", meta: { active: true, label: "meta-72" },
};
const preserved72 = preserve72(model72);
/** @type {Box72<Model72>} */
const box72 = { value: preserved72, label: "box-72" };
/** @type {Project72} */
const project72 = (input) => `${input.meta.label}:${input.name}`;
const store72 = new Store72(box72);
const rendered72 = store72.read(project72);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult72 = {
  id: preserved72.id,
  name: preserved72.name,
  active: preserved72.meta.active,
  rendered: rendered72,
};

/**
 * @typedef {object} Model73
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box73
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project73
 * @param {Model73} input
 * @returns {string}
 */

/**
 * @template {Model73} T
 * @param {T} value
 * @returns {T}
 */
function preserve73(value) {
  return value;
}

class Store73 {
  /**
   * @param {Box73<Model73>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project73} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model73} */
const model73 = {
  id: 73, name: "model-73", meta: { active: false, label: "meta-73" },
};
const preserved73 = preserve73(model73);
/** @type {Box73<Model73>} */
const box73 = { value: preserved73, label: "box-73" };
/** @type {Project73} */
const project73 = (input) => `${input.meta.label}:${input.name}`;
const store73 = new Store73(box73);
const rendered73 = store73.read(project73);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult73 = {
  id: preserved73.id,
  name: preserved73.name,
  active: preserved73.meta.active,
  rendered: rendered73,
};

/**
 * @typedef {object} Model74
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box74
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project74
 * @param {Model74} input
 * @returns {string}
 */

/**
 * @template {Model74} T
 * @param {T} value
 * @returns {T}
 */
function preserve74(value) {
  return value;
}

class Store74 {
  /**
   * @param {Box74<Model74>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project74} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model74} */
const model74 = {
  id: 74, name: "model-74", meta: { active: true, label: "meta-74" },
};
const preserved74 = preserve74(model74);
/** @type {Box74<Model74>} */
const box74 = { value: preserved74, label: "box-74" };
/** @type {Project74} */
const project74 = (input) => `${input.meta.label}:${input.name}`;
const store74 = new Store74(box74);
const rendered74 = store74.read(project74);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult74 = {
  id: preserved74.id,
  name: preserved74.name,
  active: preserved74.meta.active,
  rendered: rendered74,
};

/**
 * @typedef {object} Model75
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box75
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project75
 * @param {Model75} input
 * @returns {string}
 */

/**
 * @template {Model75} T
 * @param {T} value
 * @returns {T}
 */
function preserve75(value) {
  return value;
}

class Store75 {
  /**
   * @param {Box75<Model75>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project75} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model75} */
const model75 = {
  id: 75, name: "model-75", meta: { active: false, label: "meta-75" },
};
const preserved75 = preserve75(model75);
/** @type {Box75<Model75>} */
const box75 = { value: preserved75, label: "box-75" };
/** @type {Project75} */
const project75 = (input) => `${input.meta.label}:${input.name}`;
const store75 = new Store75(box75);
const rendered75 = store75.read(project75);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult75 = {
  id: preserved75.id,
  name: preserved75.name,
  active: preserved75.meta.active,
  rendered: rendered75,
};

/**
 * @typedef {object} Model76
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box76
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project76
 * @param {Model76} input
 * @returns {string}
 */

/**
 * @template {Model76} T
 * @param {T} value
 * @returns {T}
 */
function preserve76(value) {
  return value;
}

class Store76 {
  /**
   * @param {Box76<Model76>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project76} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model76} */
const model76 = {
  id: 76, name: "model-76", meta: { active: true, label: "meta-76" },
};
const preserved76 = preserve76(model76);
/** @type {Box76<Model76>} */
const box76 = { value: preserved76, label: "box-76" };
/** @type {Project76} */
const project76 = (input) => `${input.meta.label}:${input.name}`;
const store76 = new Store76(box76);
const rendered76 = store76.read(project76);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult76 = {
  id: preserved76.id,
  name: preserved76.name,
  active: preserved76.meta.active,
  rendered: rendered76,
};

/**
 * @typedef {object} Model77
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box77
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project77
 * @param {Model77} input
 * @returns {string}
 */

/**
 * @template {Model77} T
 * @param {T} value
 * @returns {T}
 */
function preserve77(value) {
  return value;
}

class Store77 {
  /**
   * @param {Box77<Model77>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project77} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model77} */
const model77 = {
  id: 77, name: "model-77", meta: { active: false, label: "meta-77" },
};
const preserved77 = preserve77(model77);
/** @type {Box77<Model77>} */
const box77 = { value: preserved77, label: "box-77" };
/** @type {Project77} */
const project77 = (input) => `${input.meta.label}:${input.name}`;
const store77 = new Store77(box77);
const rendered77 = store77.read(project77);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult77 = {
  id: preserved77.id,
  name: preserved77.name,
  active: preserved77.meta.active,
  rendered: rendered77,
};

/**
 * @typedef {object} Model78
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box78
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project78
 * @param {Model78} input
 * @returns {string}
 */

/**
 * @template {Model78} T
 * @param {T} value
 * @returns {T}
 */
function preserve78(value) {
  return value;
}

class Store78 {
  /**
   * @param {Box78<Model78>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project78} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model78} */
const model78 = {
  id: 78, name: "model-78", meta: { active: true, label: "meta-78" },
};
const preserved78 = preserve78(model78);
/** @type {Box78<Model78>} */
const box78 = { value: preserved78, label: "box-78" };
/** @type {Project78} */
const project78 = (input) => `${input.meta.label}:${input.name}`;
const store78 = new Store78(box78);
const rendered78 = store78.read(project78);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult78 = {
  id: preserved78.id,
  name: preserved78.name,
  active: preserved78.meta.active,
  rendered: rendered78,
};

/**
 * @typedef {object} Model79
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box79
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project79
 * @param {Model79} input
 * @returns {string}
 */

/**
 * @template {Model79} T
 * @param {T} value
 * @returns {T}
 */
function preserve79(value) {
  return value;
}

class Store79 {
  /**
   * @param {Box79<Model79>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project79} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model79} */
const model79 = {
  id: 79, name: "model-79", meta: { active: false, label: "meta-79" },
};
const preserved79 = preserve79(model79);
/** @type {Box79<Model79>} */
const box79 = { value: preserved79, label: "box-79" };
/** @type {Project79} */
const project79 = (input) => `${input.meta.label}:${input.name}`;
const store79 = new Store79(box79);
const rendered79 = store79.read(project79);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult79 = {
  id: preserved79.id,
  name: preserved79.name,
  active: preserved79.meta.active,
  rendered: rendered79,
};

/**
 * @typedef {object} Model80
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box80
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project80
 * @param {Model80} input
 * @returns {string}
 */

/**
 * @template {Model80} T
 * @param {T} value
 * @returns {T}
 */
function preserve80(value) {
  return value;
}

class Store80 {
  /**
   * @param {Box80<Model80>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project80} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model80} */
const model80 = {
  id: 80, name: "model-80", meta: { active: true, label: "meta-80" },
};
const preserved80 = preserve80(model80);
/** @type {Box80<Model80>} */
const box80 = { value: preserved80, label: "box-80" };
/** @type {Project80} */
const project80 = (input) => `${input.meta.label}:${input.name}`;
const store80 = new Store80(box80);
const rendered80 = store80.read(project80);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult80 = {
  id: preserved80.id,
  name: preserved80.name,
  active: preserved80.meta.active,
  rendered: rendered80,
};

/**
 * @typedef {object} Model81
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box81
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project81
 * @param {Model81} input
 * @returns {string}
 */

/**
 * @template {Model81} T
 * @param {T} value
 * @returns {T}
 */
function preserve81(value) {
  return value;
}

class Store81 {
  /**
   * @param {Box81<Model81>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project81} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model81} */
const model81 = {
  id: 81, name: "model-81", meta: { active: false, label: "meta-81" },
};
const preserved81 = preserve81(model81);
/** @type {Box81<Model81>} */
const box81 = { value: preserved81, label: "box-81" };
/** @type {Project81} */
const project81 = (input) => `${input.meta.label}:${input.name}`;
const store81 = new Store81(box81);
const rendered81 = store81.read(project81);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult81 = {
  id: preserved81.id,
  name: preserved81.name,
  active: preserved81.meta.active,
  rendered: rendered81,
};

/**
 * @typedef {object} Model82
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box82
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project82
 * @param {Model82} input
 * @returns {string}
 */

/**
 * @template {Model82} T
 * @param {T} value
 * @returns {T}
 */
function preserve82(value) {
  return value;
}

class Store82 {
  /**
   * @param {Box82<Model82>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project82} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model82} */
const model82 = {
  id: 82, name: "model-82", meta: { active: true, label: "meta-82" },
};
const preserved82 = preserve82(model82);
/** @type {Box82<Model82>} */
const box82 = { value: preserved82, label: "box-82" };
/** @type {Project82} */
const project82 = (input) => `${input.meta.label}:${input.name}`;
const store82 = new Store82(box82);
const rendered82 = store82.read(project82);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult82 = {
  id: preserved82.id,
  name: preserved82.name,
  active: preserved82.meta.active,
  rendered: rendered82,
};

/**
 * @typedef {object} Model83
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box83
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project83
 * @param {Model83} input
 * @returns {string}
 */

/**
 * @template {Model83} T
 * @param {T} value
 * @returns {T}
 */
function preserve83(value) {
  return value;
}

class Store83 {
  /**
   * @param {Box83<Model83>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project83} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model83} */
const model83 = {
  id: 83, name: "model-83", meta: { active: false, label: "meta-83" },
};
const preserved83 = preserve83(model83);
/** @type {Box83<Model83>} */
const box83 = { value: preserved83, label: "box-83" };
/** @type {Project83} */
const project83 = (input) => `${input.meta.label}:${input.name}`;
const store83 = new Store83(box83);
const rendered83 = store83.read(project83);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult83 = {
  id: preserved83.id,
  name: preserved83.name,
  active: preserved83.meta.active,
  rendered: rendered83,
};

/**
 * @typedef {object} Model84
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box84
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project84
 * @param {Model84} input
 * @returns {string}
 */

/**
 * @template {Model84} T
 * @param {T} value
 * @returns {T}
 */
function preserve84(value) {
  return value;
}

class Store84 {
  /**
   * @param {Box84<Model84>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project84} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model84} */
const model84 = {
  id: 84, name: "model-84", meta: { active: true, label: "meta-84" },
};
const preserved84 = preserve84(model84);
/** @type {Box84<Model84>} */
const box84 = { value: preserved84, label: "box-84" };
/** @type {Project84} */
const project84 = (input) => `${input.meta.label}:${input.name}`;
const store84 = new Store84(box84);
const rendered84 = store84.read(project84);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult84 = {
  id: preserved84.id,
  name: preserved84.name,
  active: preserved84.meta.active,
  rendered: rendered84,
};

/**
 * @typedef {object} Model85
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box85
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project85
 * @param {Model85} input
 * @returns {string}
 */

/**
 * @template {Model85} T
 * @param {T} value
 * @returns {T}
 */
function preserve85(value) {
  return value;
}

class Store85 {
  /**
   * @param {Box85<Model85>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project85} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model85} */
const model85 = {
  id: 85, name: "model-85", meta: { active: false, label: "meta-85" },
};
const preserved85 = preserve85(model85);
/** @type {Box85<Model85>} */
const box85 = { value: preserved85, label: "box-85" };
/** @type {Project85} */
const project85 = (input) => `${input.meta.label}:${input.name}`;
const store85 = new Store85(box85);
const rendered85 = store85.read(project85);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult85 = {
  id: preserved85.id,
  name: preserved85.name,
  active: preserved85.meta.active,
  rendered: rendered85,
};

/**
 * @typedef {object} Model86
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box86
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project86
 * @param {Model86} input
 * @returns {string}
 */

/**
 * @template {Model86} T
 * @param {T} value
 * @returns {T}
 */
function preserve86(value) {
  return value;
}

class Store86 {
  /**
   * @param {Box86<Model86>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project86} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model86} */
const model86 = {
  id: 86, name: "model-86", meta: { active: true, label: "meta-86" },
};
const preserved86 = preserve86(model86);
/** @type {Box86<Model86>} */
const box86 = { value: preserved86, label: "box-86" };
/** @type {Project86} */
const project86 = (input) => `${input.meta.label}:${input.name}`;
const store86 = new Store86(box86);
const rendered86 = store86.read(project86);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult86 = {
  id: preserved86.id,
  name: preserved86.name,
  active: preserved86.meta.active,
  rendered: rendered86,
};

/**
 * @typedef {object} Model87
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box87
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project87
 * @param {Model87} input
 * @returns {string}
 */

/**
 * @template {Model87} T
 * @param {T} value
 * @returns {T}
 */
function preserve87(value) {
  return value;
}

class Store87 {
  /**
   * @param {Box87<Model87>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project87} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model87} */
const model87 = {
  id: 87, name: "model-87", meta: { active: false, label: "meta-87" },
};
const preserved87 = preserve87(model87);
/** @type {Box87<Model87>} */
const box87 = { value: preserved87, label: "box-87" };
/** @type {Project87} */
const project87 = (input) => `${input.meta.label}:${input.name}`;
const store87 = new Store87(box87);
const rendered87 = store87.read(project87);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult87 = {
  id: preserved87.id,
  name: preserved87.name,
  active: preserved87.meta.active,
  rendered: rendered87,
};

/**
 * @typedef {object} Model88
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box88
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project88
 * @param {Model88} input
 * @returns {string}
 */

/**
 * @template {Model88} T
 * @param {T} value
 * @returns {T}
 */
function preserve88(value) {
  return value;
}

class Store88 {
  /**
   * @param {Box88<Model88>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project88} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model88} */
const model88 = {
  id: 88, name: "model-88", meta: { active: true, label: "meta-88" },
};
const preserved88 = preserve88(model88);
/** @type {Box88<Model88>} */
const box88 = { value: preserved88, label: "box-88" };
/** @type {Project88} */
const project88 = (input) => `${input.meta.label}:${input.name}`;
const store88 = new Store88(box88);
const rendered88 = store88.read(project88);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult88 = {
  id: preserved88.id,
  name: preserved88.name,
  active: preserved88.meta.active,
  rendered: rendered88,
};

/**
 * @typedef {object} Model89
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box89
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project89
 * @param {Model89} input
 * @returns {string}
 */

/**
 * @template {Model89} T
 * @param {T} value
 * @returns {T}
 */
function preserve89(value) {
  return value;
}

class Store89 {
  /**
   * @param {Box89<Model89>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project89} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model89} */
const model89 = {
  id: 89, name: "model-89", meta: { active: false, label: "meta-89" },
};
const preserved89 = preserve89(model89);
/** @type {Box89<Model89>} */
const box89 = { value: preserved89, label: "box-89" };
/** @type {Project89} */
const project89 = (input) => `${input.meta.label}:${input.name}`;
const store89 = new Store89(box89);
const rendered89 = store89.read(project89);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult89 = {
  id: preserved89.id,
  name: preserved89.name,
  active: preserved89.meta.active,
  rendered: rendered89,
};

/**
 * @typedef {object} Model90
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box90
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project90
 * @param {Model90} input
 * @returns {string}
 */

/**
 * @template {Model90} T
 * @param {T} value
 * @returns {T}
 */
function preserve90(value) {
  return value;
}

class Store90 {
  /**
   * @param {Box90<Model90>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project90} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model90} */
const model90 = {
  id: 90, name: "model-90", meta: { active: true, label: "meta-90" },
};
const preserved90 = preserve90(model90);
/** @type {Box90<Model90>} */
const box90 = { value: preserved90, label: "box-90" };
/** @type {Project90} */
const project90 = (input) => `${input.meta.label}:${input.name}`;
const store90 = new Store90(box90);
const rendered90 = store90.read(project90);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult90 = {
  id: preserved90.id,
  name: preserved90.name,
  active: preserved90.meta.active,
  rendered: rendered90,
};

/**
 * @typedef {object} Model91
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box91
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project91
 * @param {Model91} input
 * @returns {string}
 */

/**
 * @template {Model91} T
 * @param {T} value
 * @returns {T}
 */
function preserve91(value) {
  return value;
}

class Store91 {
  /**
   * @param {Box91<Model91>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project91} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model91} */
const model91 = {
  id: 91, name: "model-91", meta: { active: false, label: "meta-91" },
};
const preserved91 = preserve91(model91);
/** @type {Box91<Model91>} */
const box91 = { value: preserved91, label: "box-91" };
/** @type {Project91} */
const project91 = (input) => `${input.meta.label}:${input.name}`;
const store91 = new Store91(box91);
const rendered91 = store91.read(project91);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult91 = {
  id: preserved91.id,
  name: preserved91.name,
  active: preserved91.meta.active,
  rendered: rendered91,
};

/**
 * @typedef {object} Model92
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box92
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project92
 * @param {Model92} input
 * @returns {string}
 */

/**
 * @template {Model92} T
 * @param {T} value
 * @returns {T}
 */
function preserve92(value) {
  return value;
}

class Store92 {
  /**
   * @param {Box92<Model92>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project92} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model92} */
const model92 = {
  id: 92, name: "model-92", meta: { active: true, label: "meta-92" },
};
const preserved92 = preserve92(model92);
/** @type {Box92<Model92>} */
const box92 = { value: preserved92, label: "box-92" };
/** @type {Project92} */
const project92 = (input) => `${input.meta.label}:${input.name}`;
const store92 = new Store92(box92);
const rendered92 = store92.read(project92);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult92 = {
  id: preserved92.id,
  name: preserved92.name,
  active: preserved92.meta.active,
  rendered: rendered92,
};

/**
 * @typedef {object} Model93
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box93
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project93
 * @param {Model93} input
 * @returns {string}
 */

/**
 * @template {Model93} T
 * @param {T} value
 * @returns {T}
 */
function preserve93(value) {
  return value;
}

class Store93 {
  /**
   * @param {Box93<Model93>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project93} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model93} */
const model93 = {
  id: 93, name: "model-93", meta: { active: false, label: "meta-93" },
};
const preserved93 = preserve93(model93);
/** @type {Box93<Model93>} */
const box93 = { value: preserved93, label: "box-93" };
/** @type {Project93} */
const project93 = (input) => `${input.meta.label}:${input.name}`;
const store93 = new Store93(box93);
const rendered93 = store93.read(project93);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult93 = {
  id: preserved93.id,
  name: preserved93.name,
  active: preserved93.meta.active,
  rendered: rendered93,
};

/**
 * @typedef {object} Model94
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box94
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project94
 * @param {Model94} input
 * @returns {string}
 */

/**
 * @template {Model94} T
 * @param {T} value
 * @returns {T}
 */
function preserve94(value) {
  return value;
}

class Store94 {
  /**
   * @param {Box94<Model94>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project94} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model94} */
const model94 = {
  id: 94, name: "model-94", meta: { active: true, label: "meta-94" },
};
const preserved94 = preserve94(model94);
/** @type {Box94<Model94>} */
const box94 = { value: preserved94, label: "box-94" };
/** @type {Project94} */
const project94 = (input) => `${input.meta.label}:${input.name}`;
const store94 = new Store94(box94);
const rendered94 = store94.read(project94);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult94 = {
  id: preserved94.id,
  name: preserved94.name,
  active: preserved94.meta.active,
  rendered: rendered94,
};

/**
 * @typedef {object} Model95
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box95
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project95
 * @param {Model95} input
 * @returns {string}
 */

/**
 * @template {Model95} T
 * @param {T} value
 * @returns {T}
 */
function preserve95(value) {
  return value;
}

class Store95 {
  /**
   * @param {Box95<Model95>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project95} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model95} */
const model95 = {
  id: 95, name: "model-95", meta: { active: false, label: "meta-95" },
};
const preserved95 = preserve95(model95);
/** @type {Box95<Model95>} */
const box95 = { value: preserved95, label: "box-95" };
/** @type {Project95} */
const project95 = (input) => `${input.meta.label}:${input.name}`;
const store95 = new Store95(box95);
const rendered95 = store95.read(project95);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult95 = {
  id: preserved95.id,
  name: preserved95.name,
  active: preserved95.meta.active,
  rendered: rendered95,
};

/**
 * @typedef {object} Model96
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box96
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project96
 * @param {Model96} input
 * @returns {string}
 */

/**
 * @template {Model96} T
 * @param {T} value
 * @returns {T}
 */
function preserve96(value) {
  return value;
}

class Store96 {
  /**
   * @param {Box96<Model96>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project96} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model96} */
const model96 = {
  id: 96, name: "model-96", meta: { active: true, label: "meta-96" },
};
const preserved96 = preserve96(model96);
/** @type {Box96<Model96>} */
const box96 = { value: preserved96, label: "box-96" };
/** @type {Project96} */
const project96 = (input) => `${input.meta.label}:${input.name}`;
const store96 = new Store96(box96);
const rendered96 = store96.read(project96);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult96 = {
  id: preserved96.id,
  name: preserved96.name,
  active: preserved96.meta.active,
  rendered: rendered96,
};

/**
 * @typedef {object} Model97
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box97
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project97
 * @param {Model97} input
 * @returns {string}
 */

/**
 * @template {Model97} T
 * @param {T} value
 * @returns {T}
 */
function preserve97(value) {
  return value;
}

class Store97 {
  /**
   * @param {Box97<Model97>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project97} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model97} */
const model97 = {
  id: 97, name: "model-97", meta: { active: false, label: "meta-97" },
};
const preserved97 = preserve97(model97);
/** @type {Box97<Model97>} */
const box97 = { value: preserved97, label: "box-97" };
/** @type {Project97} */
const project97 = (input) => `${input.meta.label}:${input.name}`;
const store97 = new Store97(box97);
const rendered97 = store97.read(project97);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult97 = {
  id: preserved97.id,
  name: preserved97.name,
  active: preserved97.meta.active,
  rendered: rendered97,
};

/**
 * @typedef {object} Model98
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box98
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project98
 * @param {Model98} input
 * @returns {string}
 */

/**
 * @template {Model98} T
 * @param {T} value
 * @returns {T}
 */
function preserve98(value) {
  return value;
}

class Store98 {
  /**
   * @param {Box98<Model98>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project98} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model98} */
const model98 = {
  id: 98, name: "model-98", meta: { active: true, label: "meta-98" },
};
const preserved98 = preserve98(model98);
/** @type {Box98<Model98>} */
const box98 = { value: preserved98, label: "box-98" };
/** @type {Project98} */
const project98 = (input) => `${input.meta.label}:${input.name}`;
const store98 = new Store98(box98);
const rendered98 = store98.read(project98);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult98 = {
  id: preserved98.id,
  name: preserved98.name,
  active: preserved98.meta.active,
  rendered: rendered98,
};

/**
 * @typedef {object} Model99
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box99
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project99
 * @param {Model99} input
 * @returns {string}
 */

/**
 * @template {Model99} T
 * @param {T} value
 * @returns {T}
 */
function preserve99(value) {
  return value;
}

class Store99 {
  /**
   * @param {Box99<Model99>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project99} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model99} */
const model99 = {
  id: 99, name: "model-99", meta: { active: false, label: "meta-99" },
};
const preserved99 = preserve99(model99);
/** @type {Box99<Model99>} */
const box99 = { value: preserved99, label: "box-99" };
/** @type {Project99} */
const project99 = (input) => `${input.meta.label}:${input.name}`;
const store99 = new Store99(box99);
const rendered99 = store99.read(project99);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult99 = {
  id: preserved99.id,
  name: preserved99.name,
  active: preserved99.meta.active,
  rendered: rendered99,
};

/**
 * @typedef {object} Model100
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box100
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project100
 * @param {Model100} input
 * @returns {string}
 */

/**
 * @template {Model100} T
 * @param {T} value
 * @returns {T}
 */
function preserve100(value) {
  return value;
}

class Store100 {
  /**
   * @param {Box100<Model100>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project100} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model100} */
const model100 = {
  id: 100, name: "model-100", meta: { active: true, label: "meta-100" },
};
const preserved100 = preserve100(model100);
/** @type {Box100<Model100>} */
const box100 = { value: preserved100, label: "box-100" };
/** @type {Project100} */
const project100 = (input) => `${input.meta.label}:${input.name}`;
const store100 = new Store100(box100);
const rendered100 = store100.read(project100);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult100 = {
  id: preserved100.id,
  name: preserved100.name,
  active: preserved100.meta.active,
  rendered: rendered100,
};

/**
 * @typedef {object} Model101
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box101
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project101
 * @param {Model101} input
 * @returns {string}
 */

/**
 * @template {Model101} T
 * @param {T} value
 * @returns {T}
 */
function preserve101(value) {
  return value;
}

class Store101 {
  /**
   * @param {Box101<Model101>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project101} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model101} */
const model101 = {
  id: 101, name: "model-101", meta: { active: false, label: "meta-101" },
};
const preserved101 = preserve101(model101);
/** @type {Box101<Model101>} */
const box101 = { value: preserved101, label: "box-101" };
/** @type {Project101} */
const project101 = (input) => `${input.meta.label}:${input.name}`;
const store101 = new Store101(box101);
const rendered101 = store101.read(project101);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult101 = {
  id: preserved101.id,
  name: preserved101.name,
  active: preserved101.meta.active,
  rendered: rendered101,
};

/**
 * @typedef {object} Model102
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box102
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project102
 * @param {Model102} input
 * @returns {string}
 */

/**
 * @template {Model102} T
 * @param {T} value
 * @returns {T}
 */
function preserve102(value) {
  return value;
}

class Store102 {
  /**
   * @param {Box102<Model102>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project102} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model102} */
const model102 = {
  id: 102, name: "model-102", meta: { active: true, label: "meta-102" },
};
const preserved102 = preserve102(model102);
/** @type {Box102<Model102>} */
const box102 = { value: preserved102, label: "box-102" };
/** @type {Project102} */
const project102 = (input) => `${input.meta.label}:${input.name}`;
const store102 = new Store102(box102);
const rendered102 = store102.read(project102);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult102 = {
  id: preserved102.id,
  name: preserved102.name,
  active: preserved102.meta.active,
  rendered: rendered102,
};

/**
 * @typedef {object} Model103
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box103
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project103
 * @param {Model103} input
 * @returns {string}
 */

/**
 * @template {Model103} T
 * @param {T} value
 * @returns {T}
 */
function preserve103(value) {
  return value;
}

class Store103 {
  /**
   * @param {Box103<Model103>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project103} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model103} */
const model103 = {
  id: 103, name: "model-103", meta: { active: false, label: "meta-103" },
};
const preserved103 = preserve103(model103);
/** @type {Box103<Model103>} */
const box103 = { value: preserved103, label: "box-103" };
/** @type {Project103} */
const project103 = (input) => `${input.meta.label}:${input.name}`;
const store103 = new Store103(box103);
const rendered103 = store103.read(project103);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult103 = {
  id: preserved103.id,
  name: preserved103.name,
  active: preserved103.meta.active,
  rendered: rendered103,
};

/**
 * @typedef {object} Model104
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box104
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project104
 * @param {Model104} input
 * @returns {string}
 */

/**
 * @template {Model104} T
 * @param {T} value
 * @returns {T}
 */
function preserve104(value) {
  return value;
}

class Store104 {
  /**
   * @param {Box104<Model104>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project104} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model104} */
const model104 = {
  id: 104, name: "model-104", meta: { active: true, label: "meta-104" },
};
const preserved104 = preserve104(model104);
/** @type {Box104<Model104>} */
const box104 = { value: preserved104, label: "box-104" };
/** @type {Project104} */
const project104 = (input) => `${input.meta.label}:${input.name}`;
const store104 = new Store104(box104);
const rendered104 = store104.read(project104);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult104 = {
  id: preserved104.id,
  name: preserved104.name,
  active: preserved104.meta.active,
  rendered: rendered104,
};

/**
 * @typedef {object} Model105
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box105
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project105
 * @param {Model105} input
 * @returns {string}
 */

/**
 * @template {Model105} T
 * @param {T} value
 * @returns {T}
 */
function preserve105(value) {
  return value;
}

class Store105 {
  /**
   * @param {Box105<Model105>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project105} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model105} */
const model105 = {
  id: 105, name: "model-105", meta: { active: false, label: "meta-105" },
};
const preserved105 = preserve105(model105);
/** @type {Box105<Model105>} */
const box105 = { value: preserved105, label: "box-105" };
/** @type {Project105} */
const project105 = (input) => `${input.meta.label}:${input.name}`;
const store105 = new Store105(box105);
const rendered105 = store105.read(project105);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult105 = {
  id: preserved105.id,
  name: preserved105.name,
  active: preserved105.meta.active,
  rendered: rendered105,
};

/**
 * @typedef {object} Model106
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box106
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project106
 * @param {Model106} input
 * @returns {string}
 */

/**
 * @template {Model106} T
 * @param {T} value
 * @returns {T}
 */
function preserve106(value) {
  return value;
}

class Store106 {
  /**
   * @param {Box106<Model106>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project106} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model106} */
const model106 = {
  id: 106, name: "model-106", meta: { active: true, label: "meta-106" },
};
const preserved106 = preserve106(model106);
/** @type {Box106<Model106>} */
const box106 = { value: preserved106, label: "box-106" };
/** @type {Project106} */
const project106 = (input) => `${input.meta.label}:${input.name}`;
const store106 = new Store106(box106);
const rendered106 = store106.read(project106);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult106 = {
  id: preserved106.id,
  name: preserved106.name,
  active: preserved106.meta.active,
  rendered: rendered106,
};

/**
 * @typedef {object} Model107
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box107
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project107
 * @param {Model107} input
 * @returns {string}
 */

/**
 * @template {Model107} T
 * @param {T} value
 * @returns {T}
 */
function preserve107(value) {
  return value;
}

class Store107 {
  /**
   * @param {Box107<Model107>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project107} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model107} */
const model107 = {
  id: 107, name: "model-107", meta: { active: false, label: "meta-107" },
};
const preserved107 = preserve107(model107);
/** @type {Box107<Model107>} */
const box107 = { value: preserved107, label: "box-107" };
/** @type {Project107} */
const project107 = (input) => `${input.meta.label}:${input.name}`;
const store107 = new Store107(box107);
const rendered107 = store107.read(project107);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult107 = {
  id: preserved107.id,
  name: preserved107.name,
  active: preserved107.meta.active,
  rendered: rendered107,
};

/**
 * @typedef {object} Model108
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box108
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project108
 * @param {Model108} input
 * @returns {string}
 */

/**
 * @template {Model108} T
 * @param {T} value
 * @returns {T}
 */
function preserve108(value) {
  return value;
}

class Store108 {
  /**
   * @param {Box108<Model108>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project108} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model108} */
const model108 = {
  id: 108, name: "model-108", meta: { active: true, label: "meta-108" },
};
const preserved108 = preserve108(model108);
/** @type {Box108<Model108>} */
const box108 = { value: preserved108, label: "box-108" };
/** @type {Project108} */
const project108 = (input) => `${input.meta.label}:${input.name}`;
const store108 = new Store108(box108);
const rendered108 = store108.read(project108);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult108 = {
  id: preserved108.id,
  name: preserved108.name,
  active: preserved108.meta.active,
  rendered: rendered108,
};

/**
 * @typedef {object} Model109
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box109
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project109
 * @param {Model109} input
 * @returns {string}
 */

/**
 * @template {Model109} T
 * @param {T} value
 * @returns {T}
 */
function preserve109(value) {
  return value;
}

class Store109 {
  /**
   * @param {Box109<Model109>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project109} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model109} */
const model109 = {
  id: 109, name: "model-109", meta: { active: false, label: "meta-109" },
};
const preserved109 = preserve109(model109);
/** @type {Box109<Model109>} */
const box109 = { value: preserved109, label: "box-109" };
/** @type {Project109} */
const project109 = (input) => `${input.meta.label}:${input.name}`;
const store109 = new Store109(box109);
const rendered109 = store109.read(project109);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult109 = {
  id: preserved109.id,
  name: preserved109.name,
  active: preserved109.meta.active,
  rendered: rendered109,
};

/**
 * @typedef {object} Model110
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box110
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project110
 * @param {Model110} input
 * @returns {string}
 */

/**
 * @template {Model110} T
 * @param {T} value
 * @returns {T}
 */
function preserve110(value) {
  return value;
}

class Store110 {
  /**
   * @param {Box110<Model110>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project110} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model110} */
const model110 = {
  id: 110, name: "model-110", meta: { active: true, label: "meta-110" },
};
const preserved110 = preserve110(model110);
/** @type {Box110<Model110>} */
const box110 = { value: preserved110, label: "box-110" };
/** @type {Project110} */
const project110 = (input) => `${input.meta.label}:${input.name}`;
const store110 = new Store110(box110);
const rendered110 = store110.read(project110);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult110 = {
  id: preserved110.id,
  name: preserved110.name,
  active: preserved110.meta.active,
  rendered: rendered110,
};

/**
 * @typedef {object} Model111
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box111
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project111
 * @param {Model111} input
 * @returns {string}
 */

/**
 * @template {Model111} T
 * @param {T} value
 * @returns {T}
 */
function preserve111(value) {
  return value;
}

class Store111 {
  /**
   * @param {Box111<Model111>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project111} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model111} */
const model111 = {
  id: 111, name: "model-111", meta: { active: false, label: "meta-111" },
};
const preserved111 = preserve111(model111);
/** @type {Box111<Model111>} */
const box111 = { value: preserved111, label: "box-111" };
/** @type {Project111} */
const project111 = (input) => `${input.meta.label}:${input.name}`;
const store111 = new Store111(box111);
const rendered111 = store111.read(project111);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult111 = {
  id: preserved111.id,
  name: preserved111.name,
  active: preserved111.meta.active,
  rendered: rendered111,
};

/**
 * @typedef {object} Model112
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box112
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project112
 * @param {Model112} input
 * @returns {string}
 */

/**
 * @template {Model112} T
 * @param {T} value
 * @returns {T}
 */
function preserve112(value) {
  return value;
}

class Store112 {
  /**
   * @param {Box112<Model112>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project112} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model112} */
const model112 = {
  id: 112, name: "model-112", meta: { active: true, label: "meta-112" },
};
const preserved112 = preserve112(model112);
/** @type {Box112<Model112>} */
const box112 = { value: preserved112, label: "box-112" };
/** @type {Project112} */
const project112 = (input) => `${input.meta.label}:${input.name}`;
const store112 = new Store112(box112);
const rendered112 = store112.read(project112);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult112 = {
  id: preserved112.id,
  name: preserved112.name,
  active: preserved112.meta.active,
  rendered: rendered112,
};

/**
 * @typedef {object} Model113
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box113
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project113
 * @param {Model113} input
 * @returns {string}
 */

/**
 * @template {Model113} T
 * @param {T} value
 * @returns {T}
 */
function preserve113(value) {
  return value;
}

class Store113 {
  /**
   * @param {Box113<Model113>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project113} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model113} */
const model113 = {
  id: 113, name: "model-113", meta: { active: false, label: "meta-113" },
};
const preserved113 = preserve113(model113);
/** @type {Box113<Model113>} */
const box113 = { value: preserved113, label: "box-113" };
/** @type {Project113} */
const project113 = (input) => `${input.meta.label}:${input.name}`;
const store113 = new Store113(box113);
const rendered113 = store113.read(project113);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult113 = {
  id: preserved113.id,
  name: preserved113.name,
  active: preserved113.meta.active,
  rendered: rendered113,
};

/**
 * @typedef {object} Model114
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box114
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project114
 * @param {Model114} input
 * @returns {string}
 */

/**
 * @template {Model114} T
 * @param {T} value
 * @returns {T}
 */
function preserve114(value) {
  return value;
}

class Store114 {
  /**
   * @param {Box114<Model114>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project114} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model114} */
const model114 = {
  id: 114, name: "model-114", meta: { active: true, label: "meta-114" },
};
const preserved114 = preserve114(model114);
/** @type {Box114<Model114>} */
const box114 = { value: preserved114, label: "box-114" };
/** @type {Project114} */
const project114 = (input) => `${input.meta.label}:${input.name}`;
const store114 = new Store114(box114);
const rendered114 = store114.read(project114);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult114 = {
  id: preserved114.id,
  name: preserved114.name,
  active: preserved114.meta.active,
  rendered: rendered114,
};

/**
 * @typedef {object} Model115
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box115
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project115
 * @param {Model115} input
 * @returns {string}
 */

/**
 * @template {Model115} T
 * @param {T} value
 * @returns {T}
 */
function preserve115(value) {
  return value;
}

class Store115 {
  /**
   * @param {Box115<Model115>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project115} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model115} */
const model115 = {
  id: 115, name: "model-115", meta: { active: false, label: "meta-115" },
};
const preserved115 = preserve115(model115);
/** @type {Box115<Model115>} */
const box115 = { value: preserved115, label: "box-115" };
/** @type {Project115} */
const project115 = (input) => `${input.meta.label}:${input.name}`;
const store115 = new Store115(box115);
const rendered115 = store115.read(project115);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult115 = {
  id: preserved115.id,
  name: preserved115.name,
  active: preserved115.meta.active,
  rendered: rendered115,
};

/**
 * @typedef {object} Model116
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box116
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project116
 * @param {Model116} input
 * @returns {string}
 */

/**
 * @template {Model116} T
 * @param {T} value
 * @returns {T}
 */
function preserve116(value) {
  return value;
}

class Store116 {
  /**
   * @param {Box116<Model116>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project116} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model116} */
const model116 = {
  id: 116, name: "model-116", meta: { active: true, label: "meta-116" },
};
const preserved116 = preserve116(model116);
/** @type {Box116<Model116>} */
const box116 = { value: preserved116, label: "box-116" };
/** @type {Project116} */
const project116 = (input) => `${input.meta.label}:${input.name}`;
const store116 = new Store116(box116);
const rendered116 = store116.read(project116);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult116 = {
  id: preserved116.id,
  name: preserved116.name,
  active: preserved116.meta.active,
  rendered: rendered116,
};

/**
 * @typedef {object} Model117
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box117
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project117
 * @param {Model117} input
 * @returns {string}
 */

/**
 * @template {Model117} T
 * @param {T} value
 * @returns {T}
 */
function preserve117(value) {
  return value;
}

class Store117 {
  /**
   * @param {Box117<Model117>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project117} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model117} */
const model117 = {
  id: 117, name: "model-117", meta: { active: false, label: "meta-117" },
};
const preserved117 = preserve117(model117);
/** @type {Box117<Model117>} */
const box117 = { value: preserved117, label: "box-117" };
/** @type {Project117} */
const project117 = (input) => `${input.meta.label}:${input.name}`;
const store117 = new Store117(box117);
const rendered117 = store117.read(project117);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult117 = {
  id: preserved117.id,
  name: preserved117.name,
  active: preserved117.meta.active,
  rendered: rendered117,
};

/**
 * @typedef {object} Model118
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box118
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project118
 * @param {Model118} input
 * @returns {string}
 */

/**
 * @template {Model118} T
 * @param {T} value
 * @returns {T}
 */
function preserve118(value) {
  return value;
}

class Store118 {
  /**
   * @param {Box118<Model118>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project118} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model118} */
const model118 = {
  id: 118, name: "model-118", meta: { active: true, label: "meta-118" },
};
const preserved118 = preserve118(model118);
/** @type {Box118<Model118>} */
const box118 = { value: preserved118, label: "box-118" };
/** @type {Project118} */
const project118 = (input) => `${input.meta.label}:${input.name}`;
const store118 = new Store118(box118);
const rendered118 = store118.read(project118);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult118 = {
  id: preserved118.id,
  name: preserved118.name,
  active: preserved118.meta.active,
  rendered: rendered118,
};

/**
 * @typedef {object} Model119
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box119
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project119
 * @param {Model119} input
 * @returns {string}
 */

/**
 * @template {Model119} T
 * @param {T} value
 * @returns {T}
 */
function preserve119(value) {
  return value;
}

class Store119 {
  /**
   * @param {Box119<Model119>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project119} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model119} */
const model119 = {
  id: 119, name: "model-119", meta: { active: false, label: "meta-119" },
};
const preserved119 = preserve119(model119);
/** @type {Box119<Model119>} */
const box119 = { value: preserved119, label: "box-119" };
/** @type {Project119} */
const project119 = (input) => `${input.meta.label}:${input.name}`;
const store119 = new Store119(box119);
const rendered119 = store119.read(project119);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult119 = {
  id: preserved119.id,
  name: preserved119.name,
  active: preserved119.meta.active,
  rendered: rendered119,
};

/**
 * @typedef {object} Model120
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box120
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project120
 * @param {Model120} input
 * @returns {string}
 */

/**
 * @template {Model120} T
 * @param {T} value
 * @returns {T}
 */
function preserve120(value) {
  return value;
}

class Store120 {
  /**
   * @param {Box120<Model120>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project120} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model120} */
const model120 = {
  id: 120, name: "model-120", meta: { active: true, label: "meta-120" },
};
const preserved120 = preserve120(model120);
/** @type {Box120<Model120>} */
const box120 = { value: preserved120, label: "box-120" };
/** @type {Project120} */
const project120 = (input) => `${input.meta.label}:${input.name}`;
const store120 = new Store120(box120);
const rendered120 = store120.read(project120);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult120 = {
  id: preserved120.id,
  name: preserved120.name,
  active: preserved120.meta.active,
  rendered: rendered120,
};

/**
 * @typedef {object} Model121
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box121
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project121
 * @param {Model121} input
 * @returns {string}
 */

/**
 * @template {Model121} T
 * @param {T} value
 * @returns {T}
 */
function preserve121(value) {
  return value;
}

class Store121 {
  /**
   * @param {Box121<Model121>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project121} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model121} */
const model121 = {
  id: 121, name: "model-121", meta: { active: false, label: "meta-121" },
};
const preserved121 = preserve121(model121);
/** @type {Box121<Model121>} */
const box121 = { value: preserved121, label: "box-121" };
/** @type {Project121} */
const project121 = (input) => `${input.meta.label}:${input.name}`;
const store121 = new Store121(box121);
const rendered121 = store121.read(project121);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult121 = {
  id: preserved121.id,
  name: preserved121.name,
  active: preserved121.meta.active,
  rendered: rendered121,
};

/**
 * @typedef {object} Model122
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box122
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project122
 * @param {Model122} input
 * @returns {string}
 */

/**
 * @template {Model122} T
 * @param {T} value
 * @returns {T}
 */
function preserve122(value) {
  return value;
}

class Store122 {
  /**
   * @param {Box122<Model122>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project122} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model122} */
const model122 = {
  id: 122, name: "model-122", meta: { active: true, label: "meta-122" },
};
const preserved122 = preserve122(model122);
/** @type {Box122<Model122>} */
const box122 = { value: preserved122, label: "box-122" };
/** @type {Project122} */
const project122 = (input) => `${input.meta.label}:${input.name}`;
const store122 = new Store122(box122);
const rendered122 = store122.read(project122);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult122 = {
  id: preserved122.id,
  name: preserved122.name,
  active: preserved122.meta.active,
  rendered: rendered122,
};

/**
 * @typedef {object} Model123
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box123
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project123
 * @param {Model123} input
 * @returns {string}
 */

/**
 * @template {Model123} T
 * @param {T} value
 * @returns {T}
 */
function preserve123(value) {
  return value;
}

class Store123 {
  /**
   * @param {Box123<Model123>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project123} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model123} */
const model123 = {
  id: 123, name: "model-123", meta: { active: false, label: "meta-123" },
};
const preserved123 = preserve123(model123);
/** @type {Box123<Model123>} */
const box123 = { value: preserved123, label: "box-123" };
/** @type {Project123} */
const project123 = (input) => `${input.meta.label}:${input.name}`;
const store123 = new Store123(box123);
const rendered123 = store123.read(project123);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult123 = {
  id: preserved123.id,
  name: preserved123.name,
  active: preserved123.meta.active,
  rendered: rendered123,
};

/**
 * @typedef {object} Model124
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box124
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project124
 * @param {Model124} input
 * @returns {string}
 */

/**
 * @template {Model124} T
 * @param {T} value
 * @returns {T}
 */
function preserve124(value) {
  return value;
}

class Store124 {
  /**
   * @param {Box124<Model124>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project124} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model124} */
const model124 = {
  id: 124, name: "model-124", meta: { active: true, label: "meta-124" },
};
const preserved124 = preserve124(model124);
/** @type {Box124<Model124>} */
const box124 = { value: preserved124, label: "box-124" };
/** @type {Project124} */
const project124 = (input) => `${input.meta.label}:${input.name}`;
const store124 = new Store124(box124);
const rendered124 = store124.read(project124);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult124 = {
  id: preserved124.id,
  name: preserved124.name,
  active: preserved124.meta.active,
  rendered: rendered124,
};

/**
 * @typedef {object} Model125
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box125
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project125
 * @param {Model125} input
 * @returns {string}
 */

/**
 * @template {Model125} T
 * @param {T} value
 * @returns {T}
 */
function preserve125(value) {
  return value;
}

class Store125 {
  /**
   * @param {Box125<Model125>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project125} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model125} */
const model125 = {
  id: 125, name: "model-125", meta: { active: false, label: "meta-125" },
};
const preserved125 = preserve125(model125);
/** @type {Box125<Model125>} */
const box125 = { value: preserved125, label: "box-125" };
/** @type {Project125} */
const project125 = (input) => `${input.meta.label}:${input.name}`;
const store125 = new Store125(box125);
const rendered125 = store125.read(project125);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult125 = {
  id: preserved125.id,
  name: preserved125.name,
  active: preserved125.meta.active,
  rendered: rendered125,
};

/**
 * @typedef {object} Model126
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box126
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project126
 * @param {Model126} input
 * @returns {string}
 */

/**
 * @template {Model126} T
 * @param {T} value
 * @returns {T}
 */
function preserve126(value) {
  return value;
}

class Store126 {
  /**
   * @param {Box126<Model126>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project126} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model126} */
const model126 = {
  id: 126, name: "model-126", meta: { active: true, label: "meta-126" },
};
const preserved126 = preserve126(model126);
/** @type {Box126<Model126>} */
const box126 = { value: preserved126, label: "box-126" };
/** @type {Project126} */
const project126 = (input) => `${input.meta.label}:${input.name}`;
const store126 = new Store126(box126);
const rendered126 = store126.read(project126);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult126 = {
  id: preserved126.id,
  name: preserved126.name,
  active: preserved126.meta.active,
  rendered: rendered126,
};

/**
 * @typedef {object} Model127
 * @property {number} id
 * @property {string} name
 * @property {{ active: boolean, label: string }} meta
 */

/**
 * @template T
 * @typedef {object} Box127
 * @property {T} value
 * @property {string} label
 */

/**
 * @callback Project127
 * @param {Model127} input
 * @returns {string}
 */

/**
 * @template {Model127} T
 * @param {T} value
 * @returns {T}
 */
function preserve127(value) {
  return value;
}

class Store127 {
  /**
   * @param {Box127<Model127>} box
   */
  constructor(box) {
    this.box = box;
  }

  /**
   * @param {Project127} project
   * @returns {string}
   */
  read(project) {
    return project(this.box.value);
  }
}

/** @type {Model127} */
const model127 = {
  id: 127, name: "model-127", meta: { active: false, label: "meta-127" },
};
const preserved127 = preserve127(model127);
/** @type {Box127<Model127>} */
const box127 = { value: preserved127, label: "box-127" };
/** @type {Project127} */
const project127 = (input) => `${input.meta.label}:${input.name}`;
const store127 = new Store127(box127);
const rendered127 = store127.read(project127);
/** @type {{ id: number, name: string, active: boolean, rendered: string }} */
export const jsdocResult127 = {
  id: preserved127.id,
  name: preserved127.name,
  active: preserved127.meta.active,
  rendered: rendered127,
};
